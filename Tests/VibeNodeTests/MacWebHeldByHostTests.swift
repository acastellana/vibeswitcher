import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The Mac's H1 (docs/process/v2-mac-tasks.md item 9; the security architecture's S11 item 32): on a scratch host on the
/// Mac with its server child (`--server`, a scratch lock, as `MacServerChildTests` starts one), the host binds the web's
/// socket when the server asks over its stream connector, holds it, and hands the server a duplicate (`SCM_RIGHTS`, the
/// message framed: `Platform.Sockets.sendConnectorMessage`). A second process can't bind the port while the server runs,
/// once it is killed (before the host starts the next), or once the next runs; the server serves the page on the
/// descriptor it was handed, on loopback only. A port another process already holds makes the web refuse with a plain
/// message, never come up on another port (item 32's "A host that finds the port taken refuses the web, and the server
/// says so in `status`"). Mac only: Linux's is `WebHeldByHostTests`.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's H1; Linux's is WebHeldByHostTests"), .serialized, .timeLimit(.minutes(5)))
struct MacWebHeldByHostTests {
    let scratch = Scratch()

    /// A Mac scratch host with its server child: a copy of the built server signed with the Hardened Runtime (the app
    /// connector's Mac check), on a short scratch root, its own lock, ended with this process (`--exit-with`).
    final class Host {
        let root: URL
        let server: String
        let process: SpawnedHost

        init(_ scratch: Scratch, serverArguments: [String]) throws {
            root = try scratch.shortFolder("vsmw")
            let folder = root.appendingPathComponent("server", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            server = folder.appendingPathComponent("vibeswitcher-server").path
            try #require(try runToEnd("/bin/cp", [builtProducts.appendingPathComponent("vibeswitcher-server").path, server]) == 0)
            try #require(try runToEnd("/usr/bin/codesign", ["--force", "-s", "-", "-o", "runtime", server]) == 0)
            let home = root.appendingPathComponent("home").path
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            let host = builtProducts.appendingPathComponent("vibeswitcher-host").path
            let socket = root.appendingPathComponent("host.sock").path, lock = root.appendingPathComponent("scratch-host.lock").path
            var arguments = [host, "--socket", socket, "--lock", lock,
                             "--log", root.appendingPathComponent("host.log").path, "--idle-exit", "120", "--server", server,
                             "--exit-with", String(getpid())]
            for argument in serverArguments { arguments += ["--server-arg", argument] }
            var spawn = Platform.Spawn(executable: host, arguments: arguments)
            spawn.environment = ["VIBESWITCHER_HOME=\(root.path)", "HOME=\(home)", "CFFIXED_USER_HOME=\(home)", "PATH=/usr/bin:/bin",
                                 "SHELL=/bin/sh", "TMPDIR=\(scratchRoot.path)"]
            spawn.stdin = .path("/dev/null", flags: O_RDONLY)
            let out = root.appendingPathComponent("host.out").path
            spawn.stdout = .path(out, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
            spawn.stderr = .path(out, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
            spawn.group = .ownGroup
            switch spawn.start() {
            case .failure(let error): throw error
            case .success(let pid): process = SpawnedHost(pid: pid)
            }
        }

        /// The host's log and output, the server's lines among them.
        var said: String {
            ["host.log", "host.out"].map { (try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) ?? "" }.joined(separator: "\n")
        }

        /// The server's socket (`<root>/v2/server.sock`).
        var serverSocket: String { root.appendingPathComponent("v2/server.sock").path }

        /// The pids of the server children the log says started, in order.
        var children: [pid_t] {
            said.components(separatedBy: "\n").filter { $0.contains("server child pid ") && $0.contains(" started from ") }
                .compactMap { $0.components(separatedBy: "server child pid ").last?.split(separator: " ").first.flatMap { pid_t(String($0)) } }
        }

        /// A client of the server once it answers, its link welcomed or not.
        func client() async throws -> WireClient {
            var made: WireClient?
            let ready = await eventually(timeout: 120) {
                guard FileManager.default.fileExists(atPath: serverSocket) else { return false }
                made = try? WireClient(path: serverSocket)
                return made != nil
            }
            try #require(ready, "the server never answered: \(said)")
            return try #require(made)
        }

        func end() async {
            kill(process.processIdentifier, SIGTERM)
            _ = await exited(process)
        }
    }

    /// The server arguments of a scratch web: a port (0: the kernel's pick), and `web.open` from this process.
    static func web(port: UInt16 = 0) -> [String] { [ServerArguments.testWebPortFlag + String(port), ServerArguments.testWebPairFlag] }

    enum Opened {
        case open(port: UInt16, code: String)
        case refused(String)
    }

    /// `web.open` on `client`: the page's port and code, or the server's refusal.
    static func open(_ client: WireClient) throws -> Opened {
        let reply = try #require(WireClient.reply(client.request("web.open")), "no reply to web.open")
        if let error = reply.error { return .refused(error.message) }
        let url = try #require(reply.result?["url"]?.string, "\(reply)")
        let rest = try #require(url.split(separator: ":").last.map(String.init))
        let port = try #require(UInt16(rest.prefix { $0.isNumber }), "\(url)")
        let code = try #require(url.components(separatedBy: "#pair=").last, "\(url)")
        return .open(port: port, code: code)
    }

    /// `status`'s `web` on `client`.
    static func web(_ client: WireClient) -> [String: NodeWire.Value]? {
        guard case .object(let web)? = WireClient.reply(client.request("status"))?.result?["web"] else { return nil }
        return web
    }

    /// A bind of `address`:`port` by this process, as a squatter would try it (`SO_REUSEADDR`): true when it bound and
    /// listened (closed again).
    static func squat(_ address: String, _ port: UInt16) -> Bool {
        guard case .success(let fd) = Platform.TCP.listen(family: .ipv4, address: address, port: port, backlog: 1) else { return false }
        Sys.close(fd)
        return true
    }

    /// A GET of `/` on 127.0.0.1:`port`, sent now.
    static func get(_ port: UInt16) throws -> WebTestClient {
        let client = try WebTestClient(port: port)
        #expect(client.send("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"))
        return client
    }

    /// A connection to `address`:`port`: whether one was made.
    static func connects(_ address: String, _ port: UInt16) -> Bool {
        guard case .success(let fd) = Platform.TCP.connect(family: .ipv4, address: address, port: port) else { return false }
        Sys.close(fd)
        return true
    }

    /// The server runs; it is killed, and before and after the host starts the next, nothing else binds the port; a page's
    /// request made in the gap is answered by the next server, on the socket the host held. Each server serves the page on
    /// the socket it was handed, on 127.0.0.1 only.
    @Test func thePortIsHeldWhileTheServerRunsIsReplacedAndBetween() async throws {
        let host = try Host(scratch, serverArguments: Self.web())
        defer { kill(host.process.processIdentifier, SIGKILL); _ = host.process.isRunning }
        let client = try await host.client()
        guard case .open(let port, let code) = try Self.open(client) else { Issue.record("web.open refused: \(host.said)"); return }
        #expect(host.said.contains("web listener loopback bound on 127.0.0.1:\(port), held for the server"), "\(host.said)")
        // A page paired, so a token is alive at rest: the next server brings its web up again (LW-D3).
        let page = try TermPage(port: port)
        _ = try page.send("auth", ["pair": .string(code), "client": .string("test")])
        let hello = try page.next()?.json
        try #require(hello?["kind"]?.string == "hello", "no hello: \(String(describing: hello)) \(host.said)")

        // While the server runs: 127.0.0.1:port is the host's, and the page is the server's, on it.
        #expect(!Self.squat("127.0.0.1", port), "bound while the server runs")
        let first = try Self.get(port)
        let head = try #require(first.response()?.head, "no answer: \(host.said)")
        #expect(head.hasPrefix("HTTP/1.1 "), "\(head)")
        // On loopback only: no other address of this Mac reaches it.
        let others = Platform.TCP.interfaceAddresses().filter { !$0.hasPrefix("127.") && HostWebListen.ipv4($0) != nil }
        for address in others { #expect(!Self.connects(address, port), "\(address):\(port) reached the page") }

        // Replaced: the server killed. Once it is gone, and before or as the host starts the next, nothing else binds.
        let old = try #require(host.children.last, "\(host.said)")
        let started = host.children.count
        kill(old, SIGKILL)
        try #require(await eventually(timeout: 60) { Platform.Processes.link(old) == nil }, "\(host.said)")
        let inTheGap = host.children.count == started
        #expect(!Self.squat("127.0.0.1", port), "bound between two servers (the next \(inTheGap ? "not yet" : "already") started)")
        // A page's request made meanwhile waits in the host's socket, and the next server answers it.
        let waiting = try Self.get(port)
        try #require(await eventually(timeout: 120) { host.children.count > started }, "no next server: \(host.said)")
        #expect(!Self.squat("127.0.0.1", port), "bound while the next server starts")
        let answered = try #require(waiting.response()?.head, "the request made between two servers wasn't answered: \(host.said)")
        #expect(answered.hasPrefix("HTTP/1.1 "), "\(answered)")
        // The next server's web is on the same port: the socket the host held, handed again.
        let next = try await host.client()
        #expect(await eventually(timeout: 60) { Self.web(next)?["port"] == .int(Int(port)) }, "\(String(describing: Self.web(next))) \(host.said)")
        #expect(!Self.squat("127.0.0.1", port), "bound while the next server runs")
        let log = (try? String(contentsOf: host.root.appendingPathComponent("host.log"), encoding: .utf8)) ?? ""
        #expect(log.components(separatedBy: "\n").filter { $0.contains("host: web listener loopback bound on") }.count == 1, "bound once, held since: \(log)")
        await host.end()
    }

    /// The Mac's residual (as Linux's `SO_REUSEADDR` one, item 32): a socket on the wildcard binds beside the host's
    /// (the Mac's BSD rule), but a connection to 127.0.0.1, the page's one name, still reaches the node's server.
    @Test func aWildcardSocketBesideTheHostsNeverTakesTheLoopbackPage() async throws {
        let host = try Host(scratch, serverArguments: Self.web())
        defer { kill(host.process.processIdentifier, SIGKILL); _ = host.process.isRunning }
        let client = try await host.client()
        guard case .open(let port, _) = try Self.open(client) else { Issue.record("web.open refused: \(host.said)"); return }
        let wildcard: Int32
        switch Platform.TCP.listen(family: .ipv4, address: "0.0.0.0", port: port, backlog: 4) {
        case .success(let fd): wildcard = fd
        case .failure:
            // Refused too: nothing beside the host's socket at all.
            await host.end()
            return
        }
        defer { Sys.close(wildcard) }
        let page = try Self.get(port)
        let head = try #require(page.response()?.head, "no answer: \(host.said)")
        #expect(head.hasPrefix("HTTP/1.1 "), "\(head)")
        var waiting = pollfd(fd: wildcard, events: Int16(POLLIN), revents: 0)
        #expect(poll(&waiting, 1, 0) == 0, "the wildcard socket took the loopback page's connection")
        await host.end()
    }

    /// A process that already holds the port (with `SO_REUSEADDR`, or with `SO_REUSEPORT` too, which the host's socket
    /// never sets) before the web is asked for: the host refuses it with a plain message, the server's web is refused and
    /// says so, nothing is bound on any other port, and the holder keeps its port.
    @Test(arguments: [false, true])
    func aPortAlreadyHeldRefusesTheWebAndBindsNothingElse(reusePort: Bool) async throws {
        let holder = socket(AF_INET, SOCK_STREAM, 0)
        try #require(holder >= 0)
        defer { Sys.close(holder) }
        var on: Int32 = 1
        _ = setsockopt(holder, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if reusePort { _ = setsockopt(holder, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0 && listen(holder, 4) == 0)
        let port = try #require(Platform.TCP.localPort(holder))

        let host = try Host(scratch, serverArguments: Self.web(port: port))
        defer { kill(host.process.processIdentifier, SIGKILL); _ = host.process.isRunning }
        let client = try await host.client()
        guard case .refused(let why) = try Self.open(client) else {
            Issue.record("the web came up on a port another process holds: \(host.said)")
            return
        }
        #expect(why.contains("127.0.0.1:\(port) couldn't be bound"), "\(why)")
        #expect(host.said.contains("host: refused the web listener loopback 127.0.0.1:\(port): 127.0.0.1:\(port) couldn't be bound"), "\(host.said)")
        let web = Self.web(client)
        #expect(web?["port"] == .null, "\(String(describing: web))")
        if case .string(let state)? = web?["state"] {
            #expect(state.hasPrefix("refused: ") && state.contains("couldn't be bound"), "\(state)")
        } else {
            Issue.record("no web state: \(String(describing: web))")
        }
        #expect(!host.said.contains("web listener loopback bound on"), "bound elsewhere: \(host.said)")
        // The holder's port is still its own: a connection reaches it.
        let reached = Self.connects("127.0.0.1", port)
        var waiting = pollfd(fd: holder, events: Int16(POLLIN), revents: 0)
        #expect(reached && poll(&waiting, 1, 5_000) == 1, "the holder lost its port")
        await host.end()
    }
}
