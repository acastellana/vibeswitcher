import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// A stand-in for the world a proxy reaches: names resolved from a table, each address it hands out a listener on
/// loopback of the test's own (an echo, or one that records what came and answers), so no request leaves the machine.
/// It records every name asked of it and every address connected to.
final class StandInWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: [EgressRules.Address]] = [:]
    private var ports: [EgressRules.Address: UInt16] = [:]
    private var resolvedNames: [String] = []
    private var connectedTo: [EgressRules.Address] = []
    private var received: [UInt8] = []
    private var listeners: [Int32] = []

    var asked: [String] { lock.withLock { resolvedNames } }
    var connections: [EgressRules.Address] { lock.withLock { connectedTo } }
    /// What the recording upstreams were sent.
    var sent: String { lock.withLock { String(decoding: received, as: UTF8.self) } }

    /// `name` resolves to `address`, where an echo (or, `recording`, a recorder answering `answer`) listens.
    func serve(_ name: String, at address: String, recording answer: String? = nil) throws {
        let address = EgressRules.Address(address)!
        let (fd, port) = try Platform.TCP.listenOnLoopback().get()
        lock.withLock {
            names[name, default: []].append(address)
            ports[address] = port
            listeners.append(fd)
        }
        let thread = Thread { [weak self] in
            while true {
                let client = Platform.Sockets.accept(fd)
                guard client >= 0 else { return }
                let each = Thread { self?.answer(client, recording: answer) }
                each.start()
            }
        }
        thread.start()
    }

    /// `name` resolves to `address`, which nothing serves.
    func resolve(_ name: String, to address: String) {
        lock.withLock { names[name, default: []].append(EgressRules.Address(address)!) }
    }

    private func answer(_ client: Int32, recording answer: String?) {
        defer { Sys.close(client) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Sys.read(client, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            if let answer {
                lock.withLock { received += buffer[0..<count] }
                if String(decoding: lock.withLock { received }, as: UTF8.self).contains("\r\n\r\n") {
                    _ = EgressProxy.Server.writeAll(client, Array(answer.utf8))
                    return
                }
            } else {
                guard EgressProxy.Server.writeAll(client, Array(buffer[0..<count])) else { return }
            }
        }
    }

    var dialer: EgressProxy.Dialer {
        EgressProxy.Dialer(resolve: { [self] name in
            lock.withLock {
                resolvedNames.append(name)
                return names[name]
            }
        }, connect: { [self] address, _, timeout in
            let port: UInt16? = lock.withLock {
                connectedTo.append(address)
                return ports[address]
            }
            guard let port else { return nil }
            return try? Platform.TCP.connect(to: [127, 0, 0, 1], port: port, timeout: timeout).get()
        })
    }

    deinit { listeners.forEach { shutdown($0, Int32(SHUT_RDWR)); Sys.close($0) } }
}

/// A box's listener as the proxy is given one (a loopback listener of the test's), and clients of it.
struct BoxListener {
    let fd: Int32
    let port: UInt16

    static func make() throws -> BoxListener {
        let (fd, port) = try Platform.TCP.listenOnLoopback().get()
        return BoxListener(fd: fd, port: port)
    }

    func connect() throws -> Int32 { try Platform.TCP.connect(to: [127, 0, 0, 1], port: port, timeout: 10).get() }
}

/// Sends `text` on `fd`.
func egressSend(_ fd: Int32, _ text: String) {
    _ = EgressProxy.Server.writeAll(fd, Array(text.utf8))
}

/// What comes on `fd` until `until` is in it, it closes, or `within` passes.
func egressReceive(_ fd: Int32, until: String? = nil, within: TimeInterval = 30) -> String {
    var bytes: [UInt8] = []
    let deadline = Date().addingTimeInterval(within)
    while until.map({ !String(decoding: bytes, as: UTF8.self).contains($0) }) ?? true {
        var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let left = deadline.timeIntervalSinceNow
        guard left > 0, poll(&waiting, 1, Int32(left * 1_000)) > 0 else { break }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Sys.read(fd, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        bytes += buffer[0..<count]
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Whether `fd`'s peer has closed it within `within` (a read gives its end, or a reset).
func closedByPeer(_ fd: Int32, within: TimeInterval = 30) -> Bool {
    var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&waiting, 1, Int32(within * 1_000)) > 0 else { return false }
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = Sys.read(fd, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        if count > 0 { continue }
        return true
    }
}

/// Lines a proxy logged.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    var log: @Sendable (String) -> Void { { [self] line in lock.withLock { lines.append(line) } } }
}

/// The egress proxy (the session sandbox plan's SB9): in this process on a stand-in world for what it carries, and as
/// the host's child for how it runs.
@Suite(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no session sandbox and no proxy"), .timeLimit(.minutes(5)))
struct EgressProxyTests {
    private let scratch = Scratch()
    static let rules = EgressRules(hosts: ["a.example", "plain.example:80"])

    /// A proxy on `world`, serving one box's listener for a session under `rules`.
    func proxy(_ world: StandInWorld, rules: EgressRules = Self.rules, limits: EgressProxy.Limits = .init(), log: LogLines = LogLines())
        throws -> (server: EgressProxy.Server, box: BoxListener, session: UUID) {
        let server = EgressProxy.Server(dialer: world.dialer, limits: limits, log: log.log)
        let box = try BoxListener.make()
        let session = UUID()
        server.add(listener: box.fd, session: session, rules: rules)
        return (server, box, session)
    }

    @Test func aTunnelToAListedHostCarriesBytesBothWays() async throws {
        let world = StandInWorld()
        try world.serve("a.example", at: "203.0.113.7")
        let (server, box, _) = try proxy(world)
        // Held to the end: a server let go serves nothing.
        defer { withExtendedLifetime(server) {} }
        let client = try box.connect()
        defer { Sys.close(client) }
        egressSend(client, "CONNECT a.example:443 HTTP/1.1\r\nHost: a.example:443\r\n\r\nearly ")
        #expect(egressReceive(client, until: "\r\n\r\n").hasPrefix("HTTP/1.1 200 "))
        let big = String(repeating: "0123456789", count: 50_000)
        egressSend(client, big + "end")
        let echoed = await Task.detached { egressReceive(client, until: "end") }.value
        #expect(echoed == "early " + big + "end")
        #expect(world.connections == [EgressRules.Address("203.0.113.7")!])
    }

    @Test func aRefusedRequestGets403AndALogLineWithNoPayload() async throws {
        let world = StandInWorld()
        try world.serve("a.example", at: "203.0.113.7")
        world.resolve("loop.example", to: "127.0.0.1")
        let log = LogLines()
        let (server, box, session) = try proxy(world, rules: EgressRules(hosts: ["a.example", "loop.example"]), log: log)
        // Held to the end: a server let go serves nothing.
        defer { withExtendedLifetime(server) {} }
        for (request, asked) in [("CONNECT evil.example:443 HTTP/1.1\r\nX-Secret: s3cr3t-header\r\n\r\ns3cr3t-body", "evil.example:443"),
                                 ("CONNECT a.example:22 HTTP/1.1\r\n\r\n", "a.example:22"),
                                 ("CONNECT 203.0.113.7:443 HTTP/1.1\r\n\r\n", "203.0.113.7:443"),
                                 ("CONNECT [::1]:443 HTTP/1.1\r\n\r\n", "[::1]:443"),
                                 ("CONNECT localhost:443 HTTP/1.1\r\n\r\n", "localhost:443"),
                                 ("CONNECT loop.example:443 HTTP/1.1\r\n\r\n", "loop.example:443")] {
            let client = try box.connect()
            defer { Sys.close(client) }
            egressSend(client, request)
            #expect(egressReceive(client, until: "\r\n\r\n").hasPrefix("HTTP/1.1 403 "), "\(asked)")
            #expect(closedByPeer(client), "\(asked)")
            #expect(log.all.contains { $0.contains(session.uuidString) && $0.contains("refused \(asked):") }, "\(asked): \(log.all)")
        }
        #expect(!log.all.contains { $0.contains("s3cr3t") }, "\(log.all)")
        // A name off the list is never resolved, an address literal never connected to; a listed name that resolves to
        // loopback is resolved, and refused before any connection.
        #expect(world.asked == ["loop.example"], "\(world.asked)")
        #expect(world.connections.isEmpty, "\(world.connections)")
    }

    @Test func eachListenerHasItsOwnList() async throws {
        let world = StandInWorld()
        try world.serve("a.example", at: "203.0.113.7")
        try world.serve("b.example", at: "203.0.113.8")
        let server = EgressProxy.Server(dialer: world.dialer, log: LogLines().log)
        let first = try BoxListener.make(), second = try BoxListener.make()
        server.add(listener: first.fd, session: UUID(), rules: EgressRules(hosts: ["a.example"]))
        server.add(listener: second.fd, session: UUID(), rules: EgressRules(hosts: ["b.example"]))
        for (box, host, allowed) in [(first, "a.example", true), (first, "b.example", false), (second, "b.example", true), (second, "a.example", false)] {
            let client = try box.connect()
            defer { Sys.close(client) }
            egressSend(client, "CONNECT \(host):443 HTTP/1.1\r\n\r\n")
            #expect(egressReceive(client, until: "\r\n\r\n").hasPrefix(allowed ? "HTTP/1.1 200 " : "HTTP/1.1 403 "), "\(host)")
        }
    }

    @Test func aSlowOrSilentClientHoldsUpNoOther() async throws {
        let world = StandInWorld()
        try world.serve("a.example", at: "203.0.113.7")
        var limits = EgressProxy.Limits()
        limits.headerSeconds = 2
        let (server, box, _) = try proxy(world, limits: limits)
        // Held to the end: a server let go serves nothing.
        defer { withExtendedLifetime(server) {} }
        // Silent, and a header that never ends.
        let silent = try box.connect(), slow = try box.connect()
        defer { Sys.close(silent); Sys.close(slow) }
        egressSend(slow, "CONNECT a.example:443 HTTP/1.1\r\nX-Slow: ")
        let client = try box.connect()
        defer { Sys.close(client) }
        egressSend(client, "CONNECT a.example:443 HTTP/1.1\r\n\r\n")
        #expect(egressReceive(client, until: "\r\n\r\n").hasPrefix("HTTP/1.1 200 "))
        egressSend(client, "ping")
        #expect(egressReceive(client, until: "ping") == "ping")
        // Each is closed once its header's time is gone.
        #expect(closedByPeer(silent) && closedByPeer(slow))
    }

    @Test func plainHttpIsCarriedOnlyToAListedHost() async throws {
        let world = StandInWorld()
        try world.serve("plain.example", at: "203.0.113.9", recording: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        let log = LogLines()
        let (server, box, _) = try proxy(world, log: log)
        // Held to the end: a server let go serves nothing.
        defer { withExtendedLifetime(server) {} }
        let client = try box.connect()
        defer { Sys.close(client) }
        egressSend(client, "GET http://plain.example/x?y=1 HTTP/1.1\r\nHost: elsewhere.example\r\nProxy-Authorization: Basic c2VjcmV0\r\nConnection: keep-alive\r\nAccept: */*\r\n\r\n")
        #expect(egressReceive(client, until: "ok").hasSuffix("ok"))
        let sent = world.sent
        #expect(sent.hasPrefix("GET /x?y=1 HTTP/1.1\r\nHost: plain.example\r\n"), "\(sent)")
        #expect(sent.contains("Accept: */*\r\n") && sent.contains("Connection: close\r\n"), "\(sent)")
        #expect(!sent.contains("elsewhere") && !sent.contains("Proxy-Authorization") && !sent.contains("keep-alive"), "\(sent)")

        for (request, status) in [("GET http://a.example/ HTTP/1.1\r\n\r\n", "403"),          // listed, but for 443 only
                                  ("GET http://other.example/ HTTP/1.1\r\n\r\n", "403"),
                                  ("GET http://plain.example:8080/ HTTP/1.1\r\n\r\n", "403"),
                                  ("GET http://user@plain.example/ HTTP/1.1\r\n\r\n", "400"),
                                  ("GET /x HTTP/1.1\r\nHost: plain.example\r\n\r\n", "400"),
                                  ("GET https://plain.example/ HTTP/1.1\r\n\r\n", "400"),
                                  ("garbage\r\n\r\n", "400")] {
            let other = try box.connect()
            defer { Sys.close(other) }
            egressSend(other, request)
            #expect(egressReceive(other, until: "\r\n\r\n").hasPrefix("HTTP/1.1 \(status) "), "\(request)")
        }
        #expect(world.connections == [EgressRules.Address("203.0.113.9")!])
    }

    /// A plain request's Host is the one the proxy writes, from the URL the rules judged. A line the proxy reads as one
    /// header and a looser host reads as two (a bare LF or CR inside it), a line carried on from the one before, or a
    /// name with a space before its colon would name a second Host past it: another site at the same address.
    @Test func aPlainRequestCantNameASecondHostPastTheProxys() async throws {
        let smuggled = ["GET http://plain.example/ HTTP/1.1\r\nX-A: b\nHost: other.example\r\n\r\n",
                        "GET http://plain.example/ HTTP/1.1\r\nX-A: b\rHost: other.example\r\n\r\n",
                        "GET http://plain.example/a\nHost:other.example HTTP/1.1\r\nAccept: */*\r\n\r\n",
                        "GET http://plain.example/ HTTP/1.1\r\nX-A: b\r\n Host: other.example\r\n\r\n",
                        "GET http://plain.example/ HTTP/1.1\r\nHost : other.example\r\n\r\n",
                        "GET http://plain.example/ HTTP/1.1\r\nHost\u{0}: other.example\r\n\r\n",
                        "GET http://plain.example/ HTTP/1.1\r\nno colon here\r\n\r\n"]
        for request in smuggled {
            guard case .failure = EgressProxy.Server.request(Array(request.utf8)) else {
                Issue.record("carried on: \(request.debugDescription)")
                continue
            }
        }
        // What an HTTP client sends goes on as before.
        let plain = try EgressProxy.Server.request(Array("GET http://plain.example/x HTTP/1.1\r\nHost: plain.example\r\nAccept: */*\r\nX-Tab:\ta\r\n\r\n".utf8)).get()
        #expect(String(decoding: plain.header, as: UTF8.self) == "GET /x HTTP/1.1\r\nHost: plain.example\r\nAccept: */*\r\nX-Tab:\ta\r\nConnection: close\r\n\r\n")
        #expect(try EgressProxy.Server.request(Array("CONNECT a.example:443 HTTP/1.1\r\nHost: a.example:443\r\n\r\n".utf8)).get().tunnel)

        // And through the proxy: 400, nothing sent on.
        let world = StandInWorld()
        try world.serve("plain.example", at: "203.0.113.9", recording: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        let (server, box, _) = try proxy(world, log: LogLines())
        defer { withExtendedLifetime(server) {} }
        let client = try box.connect()
        defer { Sys.close(client) }
        egressSend(client, smuggled[0])
        #expect(egressReceive(client, until: "\r\n\r\n").hasPrefix("HTTP/1.1 400 "))
        #expect(world.sent.isEmpty && world.connections.isEmpty)
    }

    @Test func aSessionsListenerIsClosedWithItsSession() async throws {
        let world = StandInWorld()
        try world.serve("a.example", at: "203.0.113.7")
        let (server, box, session) = try proxy(world)
        let client = try box.connect()
        defer { Sys.close(client) }
        egressSend(client, "CONNECT a.example:443 HTTP/1.1\r\n\r\n")
        #expect(egressReceive(client, until: "\r\n\r\n").hasPrefix("HTTP/1.1 200 "))
        server.end(session: session)
        #expect(closedByPeer(client), "its open tunnel is cut")
        #expect(server.served.isEmpty)
        #expect(await eventually(timeout: 30) { (try? box.connect()).map { Sys.close($0); return false } ?? true }, "its listener is closed")
    }

    /// A connection's descriptors closed, their numbers given to another connection: ending the old one cuts nothing.
    ///
    /// The number is taken only as the system gives it out again (the lowest free one, so nearly always at once), never
    /// forced with `dup2`: this process runs other tests beside this one, and a number closed here may be theirs a
    /// moment later. Forcing it replaced whatever they had just opened under it (a file, a folder, a listener) and
    /// failed them at random. When another thread was given the number first, the try is made again.
    @Test func anEndedConnectionNeverShutsADescriptorNumberGivenOutAgain() async throws {
        for _ in 0..<200 {
            let old = try #require(Platform.Sockets.pair(type: Platform.Sockets.stream))
            let connection = EgressProxy.Server.Connection(client: old.0)
            let number = old.0
            connection.close()
            Sys.close(old.1)
            // A fresh connection, on the same number when the system hands it out again.
            let fresh = try #require(Platform.Sockets.pair(type: Platform.Sockets.stream))
            guard fresh.0 == number || fresh.1 == number else {
                Sys.close(fresh.0)
                Sys.close(fresh.1)
                continue
            }
            let (reused, other) = fresh.0 == number ? (fresh.0, fresh.1) : (fresh.1, fresh.0)
            defer {
                Sys.close(reused)
                Sys.close(other)
            }
            connection.end()
            egressSend(other, "still")
            #expect(egressReceive(reused, until: "still", within: 5) == "still", "the reused number was shut")
            egressSend(reused, "both ways")
            #expect(egressReceive(other, until: "both ways", within: 5) == "both ways")
            return
        }
        Issue.record("the number was never given out again here: nothing was checked")
    }

    @Test func theLimitsHold() async throws {
        let world = StandInWorld()
        try world.serve("a.example", at: "203.0.113.7")
        var limits = EgressProxy.Limits()
        limits.connectionsPerSession = 2
        limits.headerBytes = 256
        limits.bytesPerConnection = 1_000
        let (server, box, _) = try proxy(world, limits: limits)
        // Held to the end: a server let go serves nothing.
        defer { withExtendedLifetime(server) {} }
        let held = try (0..<2).map { _ in try box.connect() }
        for fd in held { egressSend(fd, "CONNECT a.example:443 HTTP/1.1\r\n\r\n") }
        for fd in held { #expect(egressReceive(fd, until: "\r\n\r\n").hasPrefix("HTTP/1.1 200 ")) }
        let third = try box.connect()
        #expect(egressReceive(third, until: "\r\n\r\n").hasPrefix("HTTP/1.1 503 "))
        Sys.close(third)
        // A tunnel ends once its bytes are spent.
        egressSend(held[0], String(repeating: "x", count: 2_000))
        #expect(closedByPeer(held[0]))
        Sys.close(held[0])
        // A header past its bytes.
        Sys.close(held[1])
        #expect(await eventually(timeout: 30) {
            guard let fd = try? box.connect() else { return false }
            defer { Sys.close(fd) }
            egressSend(fd, "CONNECT a.example:443 HTTP/1.1\r\nX-Long: " + String(repeating: "y", count: 400) + "\r\n\r\n")
            return egressReceive(fd, until: "\r\n\r\n").hasPrefix("HTTP/1.1 431 ")
        })
    }

    @Test func theProxyIsNotDumpableAndIsStartedAgain() async throws {
        let copy = try Platform.ProcessSelf.sealedCopy(of: hostLauncher, name: "egress").get()
        defer { Sys.close(copy.fd) }
        let log = LogLines()
        let child = EgressChild(image: copy, environment: ["HOME=\(scratch.url("home").path)", "PATH=/usr/bin:/bin"], restartAfter: 0.1, log: log.log)
        defer { child.stop() }
        child.start()
        let box = try BoxListener.make()
        child.add(listener: box.fd, session: UUID(), rules: EgressRules(hosts: ["a.example"]))
        #expect(await eventually(timeout: 30) { child.pid != nil })
        let first = try #require(child.pid)
        #expect(await eventually(timeout: 30) { Platform.Processes.isDumpable(first) == false })
        // Served: a name off the list is refused there (nothing is resolved or reached).
        func refusedThere() throws -> Bool {
            let client = try box.connect()
            defer { Sys.close(client) }
            egressSend(client, "CONNECT off.example:443 HTTP/1.1\r\n\r\n")
            return egressReceive(client, until: "\r\n\r\n").hasPrefix("HTTP/1.1 403 ")
        }
        #expect(try refusedThere(), "\(log.all)")
        kill(first, SIGKILL)
        #expect(await eventually(timeout: 30) { child.pid.map { $0 != first } ?? false }, "\(log.all)")
        let second = try #require(child.pid)
        #expect(await eventually(timeout: 30) { Platform.Processes.isDumpable(second) == false })
        // The box's listener was given to it again.
        #expect(try refusedThere(), "\(log.all)")
        #expect(child.started == 2)
    }

    @Test func theProxyEndsWithItsControlAndTakesOnlyWellFormedMessages() async throws {
        let copy = try Platform.ProcessSelf.sealedCopy(of: hostLauncher, name: "egress").get()
        defer { Sys.close(copy.fd) }
        let pair = try #require(Platform.Sockets.pair(type: Platform.Sockets.seqpacket))
        var spawn = Platform.Spawn(executable: copy.path, arguments: ["vibeswitcher-host", EgressProxy.flag, EgressProxy.controlFlag, String(pair.1)])
        spawn.environment = ["\(Platform.ProcessSelf.imageVariable)=\(copy.fd)", "PATH=/usr/bin:/bin"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = [copy.fd, pair.1]
        let pid = try spawn.start().get()
        Sys.close(pair.1)
        // An add without its listener, and junk with a descriptor: both dropped, the proxy serving on.
        let box = try BoxListener.make()
        let add = Array(try JSONEncoder().encode(EgressProxy.Control.add(session: UUID(), rules: EgressRules(hosts: []))))
        #expect(Platform.Sockets.send(add, with: [], over: pair.0) > 0)
        #expect(Platform.Sockets.send(Array("junk".utf8), with: [box.fd], over: pair.0) > 0)
        #expect(Platform.Sockets.send(add, with: [box.fd], over: pair.0) > 0)
        let client = try box.connect()
        egressSend(client, "CONNECT off.example:443 HTTP/1.1\r\n\r\n")
        #expect(egressReceive(client, until: "\r\n\r\n").hasPrefix("HTTP/1.1 403 "))
        Sys.close(client)
        Sys.close(box.fd)
        Sys.close(pair.0)
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(30)
        var found: pid_t = 0
        while Date() < deadline {
            found = waitpid(pid, &status, WNOHANG)
            if found == pid { break }
            usleep(20_000)
        }
        if found != pid { kill(pid, SIGKILL); waitpid(pid, &status, 0) }
        #expect(found == pid && status == 0)
    }
}
