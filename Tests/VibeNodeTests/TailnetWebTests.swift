import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The node's page on the user's tailnet (the remote access note, docs/superpowers/specs/2026-11-20-v2-remote-access.md):
/// where it binds (Tailscale's answer, read and checked), its one name (the MagicDNS name, never the address), its own
/// gate (8 h tokens in their own file, never a loopback code or token), the peer check, and `revoke`. No case runs the
/// real `tailscale`: the lookup is a test's, which names 127.0.0.1 as the address so a socket can be opened to it.
@Suite(.timeLimit(.minutes(5)))
struct TailnetWebTests {
    private let scratch = Scratch()
    private static let name = "node-1.tail-test.ts.net"
    private static let place = TailnetPlace(address: "127.0.0.1", name: name)

    // MARK: Where it binds

    @Test func onlyTailscalesRangesAreTailnetAddresses() {
        for address in ["100.64.0.0", "100.64.0.1", "100.83.207.94", "100.127.255.255", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::cf5e"] {
            #expect(Platform.TCP.isTailscaleAddress(address), "\(address)")
        }
        for address in ["100.63.255.255", "100.128.0.0", "10.0.0.1", "192.168.1.36", "127.0.0.1", "0.0.0.0", "::1", "fd7a:115c:a1e1::1",
                        "::ffff:100.64.0.1", "100.64.0", "100.64.0.1.ts.net", "", "fd7a:115c:a1e0::1%eth0"] {
            #expect(!Platform.TCP.isTailscaleAddress(address), "\(address)")
        }
    }

    /// `tailscale status --json`, as much of it as is read.
    private static func status(state: String = "Running", magicDNS: Bool? = true, dnsName: String? = "Node-1.Tail-Test.ts.net.",
                               ips: [String] = ["100.83.207.94", "fd7a:115c:a1e0::b435:cf5e"]) -> Data {
        var own: [String: Any] = ["TailscaleIPs": ips]
        if let dnsName { own["DNSName"] = dnsName }
        var top: [String: Any] = ["BackendState": state, "Self": own]
        if let magicDNS { top["CurrentTailnet"] = ["MagicDNSEnabled": magicDNS] }
        return (try? JSONSerialization.data(withJSONObject: top)) ?? Data()
    }

    @Test func thePlaceIsTheMagicDNSNameAndTheTailnetsIPv4Address() throws {
        let found = try Tailnet.place(statusJSON: Self.status(), interfaces: ["127.0.0.1", "192.168.1.36", "100.83.207.94"]).get()
        #expect(found == TailnetPlace(address: "100.83.207.94", name: "node-1.tail-test.ts.net"))
    }

    /// Each answer that names no safe place is refused, saying which: not running, MagicDNS off (the address alone is no
    /// name: a phone with Tailscale off would send its token to the carrier's 100.64/10), no `ts.net` name, no IPv4
    /// address in the range, the address on none of this machine's interfaces, and what isn't a status at all.
    @Test func anAnswerThatNamesNoSafePlaceIsRefused() {
        let interfaces = ["127.0.0.1", "100.83.207.94", "192.168.1.36"]
        let cases: [(Data, String)] = [
            (Self.status(state: "Stopped"), "isn't connected"),
            (Self.status(state: "NeedsLogin"), "isn't connected"),
            (Self.status(magicDNS: false), "MagicDNS is off"),
            (Self.status(magicDNS: nil), "MagicDNS is off"),
            (Self.status(dnsName: nil), "no MagicDNS name"),
            (Self.status(dnsName: "node.example.com."), "no MagicDNS name"),
            (Self.status(ips: ["fd7a:115c:a1e0::b435:cf5e"]), "no IPv4 address"),
            (Self.status(ips: ["192.168.1.36"]), "no IPv4 address"),
            (Self.status(ips: ["100.83.207.95"]), "on none of its interfaces"),
            (Data("not json".utf8), "no status"),
        ]
        for (json, says) in cases {
            switch Tailnet.place(statusJSON: json, interfaces: interfaces) {
            case .success(let place): Issue.record("\(says): \(place) taken")
            case .failure(let refusal): #expect(refusal.description.contains(says), "\(says): \(refusal)")
            }
        }
    }

    @Test func aNameIsAMagicDNSNameOrNothing() {
        #expect(Tailnet.name("Node-1.Tail-Test.TS.NET.") == "node-1.tail-test.ts.net")
        #expect(Tailnet.name("node-1.tail-test.ts.net") == "node-1.tail-test.ts.net")
        for wrong in [nil, "", "ts.net", "node.ts.net.evil", "node.example.com", "node_1.tail.ts.net", "node..tail.ts.net", "-node.tail.ts.net",
                      "node.tail.ts.net:443", "evil.com/x.tail.ts.net", "node tail.ts.net", "nöde.tail.ts.net", String(repeating: "a", count: 64) + ".t.ts.net"] {
            #expect(Tailnet.name(wrong) == nil, "\(wrong ?? "nil")")
        }
    }

    /// Only a `tailscale` only root can change is run: none there says Tailscale isn't installed; one a process of the
    /// user's could change is refused, naming it, and a root-only one after it is taken.
    @Test func onlyARootOnlyTailscaleIsRun() throws {
        let root: Platform.Tools.FileStatus = (0, S_IFDIR | 0o755, false)
        let rootProgram: Platform.Tools.FileStatus = (0, S_IFREG | 0o755, true)
        let users: Platform.Tools.FileStatus = (1000, S_IFREG | 0o755, true)
        let places = ["/home/u/bin/tailscale", "/usr/bin/tailscale"]
        let table: [String: Platform.Tools.FileStatus] = ["/": root, "/usr": root, "/usr/bin": root, "/usr/bin/tailscale": rootProgram,
                                                          "/home": root, "/home/u": (users.owner, S_IFDIR | 0o755, false),
                                                          "/home/u/bin": (users.owner, S_IFDIR | 0o755, false), "/home/u/bin/tailscale": users]
        let status: (String) -> Platform.Tools.FileStatus? = { table[$0] }
        #expect(try Tailnet.program(places: places, exists: { table[$0] != nil }, status: status).get() == "/usr/bin/tailscale")
        switch Tailnet.program(places: ["/home/u/bin/tailscale"], exists: { table[$0] != nil }, status: status) {
        case .success(let program): Issue.record("\(program) taken")
        case .failure(let refusal): #expect(refusal.description.contains("/home/u/bin/tailscale") && refusal.description.contains("only root"), "\(refusal)")
        }
        switch Tailnet.program(places: places, exists: { _ in false }, status: status) {
        case .success(let program): Issue.record("\(program) taken")
        case .failure(let refusal): #expect(refusal.description.contains("isn't installed") && refusal.description.contains("doesn't install"), "\(refusal)")
        }
    }

    // MARK: Its gate

    @Test func aTailnetTokenLivesEightHoursInItsOwnFile() throws {
        let root = scratch.url("web-root")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let remote = WebTokens.tailnet(root: root), local = WebTokens(root: root)
        let issued = try remote.issue(now: start)
        #expect(issued.expiresAt == start.addingTimeInterval(8 * 3600))
        #expect(remote.url.lastPathComponent == "web-tokens-tailnet.json" && local.url.lastPathComponent == "web-tokens.json")
        #expect(FileManager.default.fileExists(atPath: remote.url.path) && !FileManager.default.fileExists(atPath: local.url.path))
        #expect(remote.check(issued.token, now: start.addingTimeInterval(8 * 3600 - 1)))
        #expect(!remote.check(issued.token, now: start.addingTimeInterval(8 * 3600)))
        #expect(!local.check(issued.token, now: start), "a tailnet token on loopback")
        #expect(!WebTokens(root: root).check(issued.token, now: start), "read again from disk")
        let loopback = try local.issue(now: start)
        #expect(!WebTokens.tailnet(root: root).check(loopback.token, now: start), "a loopback token on the tailnet")
        // At most 4: the fifth drops the oldest.
        let first = try remote.issue(now: start)
        for _ in 0..<4 { _ = try remote.issue(now: start) }
        #expect(!remote.check(first.token, now: start) && remote.live(now: start) == 4)
    }

    // MARK: The listener

    /// The rig: a `TailnetWeb` whose lookup names `place` (127.0.0.1 and a `ts.net` name) and whose peer check is
    /// `admitPeer`, on the kernel's port, a handler that records, the embedded page files.
    private final class Rig: @unchecked Sendable {
        let web: TailnetWeb
        let handler = RecordingHandler()
        let lookups = Locked(0)
        let notes = Locked<[String]>([])
        let root: URL

        init(_ scratch: Scratch, root: URL? = nil, place: Result<TailnetPlace, WebTokens.Refusal> = .success(TailnetWebTests.place),
             admitPeer: @escaping @Sendable (String) -> Bool = { _ in true }) {
            let root = root ?? scratch.url("node-root")
            self.root = root
            let lookups = lookups, notes = notes
            web = TailnetWeb(root: root, queue: DispatchQueue(label: "tailnet-tests"), clock: WebTestTime().clock(), port: 0,
                             find: { lookups.mutate { $0 += 1 }; return place }, admitPeer: admitPeer,
                             handler: WebRequestScreen(handler), hello: { admission in
                                 NodeWire.line(NodeWire.Value.object(["v": .int(NodeWire.version), "kind": .string("hello"), "auth": admission.auth])).dropLast()
                             }, note: { line in notes.mutate { $0.append(line) } })
        }

        func open() async throws -> (url: String, port: UInt16, code: String) {
            let result = Locked<Result<WebAccess.Opened, WebTokens.Refusal>?>(nil)
            web.open { result.value = $0 }
            try #require(await eventually { result.value != nil }, "open never answered")
            let opened = try #require(result.value).get()
            let code = try #require(opened.url.components(separatedBy: "#pair=").last)
            return (opened.url, opened.port, code)
        }

        var port: UInt16? {
            if case .on(_, let port) = web.state { return port }
            return nil
        }

        /// Every tailnet token dropped: the listener is let go by the block `revoke` queues, run once a later one has.
        func stop() {
            _ = web.revoke()
            web.queue.sync {}
        }
    }

    private static func upgraded(port: UInt16) throws -> RawClient {
        let client = try RawClient(port: port)
        let status = try client.upgrade(host: "\(name):\(port)", origin: "http://\(name):\(port)")
        guard status == 101 else { throw RawClient.Failure("the upgrade was answered \(status)") }
        return client
    }

    /// `open` binds where the lookup says and prints the MagicDNS name's address with a code of the tailnet's gate,
    /// taken once on a socket from the page's own origin.
    @Test func openingBindsTheTailnetAndPrintsTheMagicDNSAddress() async throws {
        let rig = Rig(scratch)
        defer { rig.stop() }
        let opened = try await rig.open()
        #expect(opened.url == "http://\(Self.name):\(opened.port)/#pair=\(opened.code)")
        #expect(rig.web.state == .on(Self.place, port: opened.port) && rig.lookups.value == 1)
        let client = try Self.upgraded(port: opened.port)
        try client.sendText(#"{"v":1,"id":"1","kind":"auth","args":{"pair":"\#(opened.code)"}}"#)
        let hello = try #require(try client.nextFrame()?.json)
        #expect(hello["kind"]?.string == "hello" && hello["auth"]?["token"]?.string?.count == 43, "\(hello)")
        #expect(rig.web.access.tokens.live(now: Date()) == 1)
        // Opened again: the listener is kept, Tailscale isn't asked again.
        _ = try await rig.open()
        #expect(rig.lookups.value == 1)
    }

    /// Host is exactly `<name>:<port>`: the address as a name, loopback's name, and any other are 421 with no body.
    /// Origin is exactly `http://<name>:<port>`. The page's policy names that socket.
    @Test func onlyTheMagicDNSNameIsTheListenersName() async throws {
        let rig = Rig(scratch)
        defer { rig.stop() }
        let port = try await rig.open().port
        for host in ["127.0.0.1:\(port)", "100.83.207.94:\(port)", "localhost:\(port)", "node-1:\(port)", "\(Self.name):\(port + 1)",
                     "\(Self.name).:\(port)", "\(Self.name)", "NODE-1.tail-test.ts.net:\(port)", "evil.example:\(port)"] {
            for target in ["/", "/ws"] {
                let upgrade = target == "/ws" ? RawClient.upgradeHeaders(origin: "http://\(Self.name):\(port)") : []
                let answer = try RawClient.ask(port: port, "GET \(target) HTTP/1.1", ["Host: \(host)"] + upgrade)
                #expect(answer.status == 421 && answer.body.isEmpty, "\(host) \(target): \(answer.head)")
            }
        }
        for origin in ["http://127.0.0.1:\(port)", "https://\(Self.name):\(port)", "http://\(Self.name)", "http://evil.example", "null"] {
            let answer = try RawClient.ask(port: port, "GET /ws HTTP/1.1", ["Host: \(Self.name):\(port)"] + RawClient.upgradeHeaders(origin: origin))
            #expect(answer.status == 403, "\(origin): \(answer.head)")
        }
        let page = try RawClient.ask(port: port, "GET / HTTP/1.1", ["Host: \(Self.name):\(port)"])
        #expect(page.status == 200, "\(page.head)")
        #expect(page.head.contains("connect-src 'self' ws://\(Self.name):\(port);"), "\(page.head)")
        #expect(!page.head.contains("127.0.0.1"), "\(page.head)")
    }

    /// A loopback code, or a loopback token, is never taken on the tailnet's listener: the two gates share nothing.
    @Test func aLoopbackCodeOrTokenIsntTakenOnTheTailnet() async throws {
        let rig = Rig(scratch)
        defer { rig.stop() }
        let port = try await rig.open().port
        let loopback = WebAccess(tokens: WebTokens(root: rig.root))
        let code = loopback.openCode(now: Date())
        let token = try loopback.tokens.issue(now: Date()).token
        for args in [#"{"pair":"\#(code)"}"#, #"{"token":"\#(token)"}"#] {
            let client = try Self.upgraded(port: port)
            try client.sendText(#"{"v":1,"id":"1","kind":"auth","args":\#(args)}"#)
            let frames = try client.framesUntilClosed()
            #expect(frames.last?.closeCode == 4401, "\(args): \(frames)")
            #expect(frames.first?.json?["reason"]?.string?.contains(TailnetWeb.command) == true, "\(frames)")
        }
        #expect(loopback.admit(["pair": .string(code)]) != nil, "the loopback code is still the loopback's")
        #expect(rig.handler.opened == 0)
    }

    /// A lookup that names no place binds nothing, makes no code, and says why; the gate wants nothing after it.
    @Test func noTailscaleBindsNothing() async throws {
        let rig = Rig(scratch, place: .failure(.init("Tailscale isn't installed here")))
        let result = Locked<Result<WebAccess.Opened, WebTokens.Refusal>?>(nil)
        rig.web.open { result.value = $0 }
        try #require(await eventually { result.value != nil })
        guard case .failure(let refusal) = result.value else {
            Issue.record("opened: \(String(describing: result.value))")
            return
        }
        #expect(refusal.description.contains("isn't installed"))
        #expect(rig.web.state == .refused("Tailscale isn't installed here"))
        #expect(!rig.web.access.wanted)
    }

    /// Revoking closes every tailnet page (`revoked`, 4403) and lets the listener go: nothing listens until `open` again.
    @Test func revokingClosesTheTailnetsPagesAndTheListener() async throws {
        let rig = Rig(scratch)
        let opened = try await rig.open()
        let client = try Self.upgraded(port: opened.port)
        try client.sendText(#"{"v":1,"id":"1","kind":"auth","args":{"pair":"\#(opened.code)"}}"#)
        #expect(try client.nextFrame()?.json?["kind"]?.string == "hello")
        try #require(await eventually { rig.handler.opened == 1 })
        #expect(try rig.web.revoke().get() == 1)
        let frames = try client.framesUntilClosed()
        #expect(frames.contains { $0.json?["code"]?.string == "revoked" } && frames.last?.closeCode == 4403, "\(frames)")
        let web = rig.web
        try #require(await eventually { web.state == .off })
        #expect(try !RawClient.connects(address: "127.0.0.1", port: opened.port))
        #expect(rig.web.access.tokens.live(now: Date()) == 0)
    }

    /// A connection from outside Tailscale's ranges is closed as it is accepted, with nothing written: Linux takes a
    /// packet for the tailnet address on any interface, so a LAN device routing to it would otherwise reach the page.
    @Test func aPeerOutsideTailscalesRangesIsClosedAtAccept() async throws {
        let rig = Rig(scratch, admitPeer: Platform.TCP.isTailscaleAddress)
        defer { rig.stop() }
        let port = try await rig.open().port
        let client = try RawClient(port: port)
        try? client.write("GET / HTTP/1.1\r\nHost: \(Self.name):\(port)\r\n\r\n")
        #expect(client.readToEnd().isEmpty)
        #expect(rig.notes.value.contains { $0.contains("outside the addresses it takes") }, "\(rig.notes.value)")
    }

    /// After a restart the listener is bound again only while a tailnet token is alive: none, nothing is asked or bound.
    @Test func aRestartBindsAgainOnlyForALiveTailnetToken() async throws {
        let root = scratch.url("node-root")
        let idle = Rig(scratch, root: root)
        idle.web.follow()
        let web = idle.web
        // `follow` runs on the queue: once a later block has run there, it has decided.
        web.queue.sync {}
        #expect(idle.lookups.value == 0 && web.state == .off)
        _ = try WebTokens.tailnet(root: root).issue(now: Date())
        let restarted = Rig(scratch, root: root)
        defer { restarted.stop() }
        restarted.web.follow()
        let again = restarted.web
        try #require(await eventually { again.port(isOn: true) }, "\(again.state)")
        #expect(restarted.lookups.value == 1)
    }

    // MARK: The user's voice

    /// `web.open` with `tailnet` is the user's voice like `web.open`: a peer that isn't is refused before Tailscale is
    /// even asked, a scratch server's open form (`--test-web-pair`) never covers it, and a server with no tailnet (a
    /// scratch one) refuses it. What the server answers the user: the MagicDNS address; `web.revoke` drops the
    /// tailnet's tokens too and says how many.
    @Test(NodeTraits.linuxOnly) func theTailnetIsOpenedInTheUsersVoiceAndRevokedWithTheRest() async throws {
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), sweep: { _ in })
        link.start()
        try #require(await eventually { link.queue.sync { link.state == .connected } }, "the link was never welcomed")
        let requests = Requests(link: link, sessions: nil, rule: CardWorld.rule, root: scratch.url("node-root"), hostSocket: stub.path,
                                commit: "test", hostPID: 1)
        requests.shutdown = { .error("not in this test") }
        let rig = Rig(scratch, root: requests.root)
        defer { rig.stop() }
        requests.web = WebAccess(tokens: WebTokens(root: requests.root))
        requests.tailnet = rig.web
        func ask(_ kind: String, _ args: [String: NodeWire.Value], from peer: PeerFacts) async -> NodeWire.Reply? {
            let reply = Locked<NodeWire.Reply?>(nil)
            requests.queue.async {
                requests.handle(NodeWire.Request(id: "r1", kind: kind, args: args, action: UUID().uuidString.lowercased()), from: peer) { reply.value = $0 }
            }
            _ = await eventually(timeout: 60) { reply.value != nil }
            return reply.value
        }
        var noTerminal = CardWorld.user
        noTerminal.terminal = .none
        for anyone in [false, true] {
            requests.openWebForAnyone = anyone
            let reply = try #require(await ask("web.open", ["tailnet": .bool(true)], from: noTerminal))
            #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "anyone: \(anyone): \(reply)")
        }
        requests.openWebForAnyone = false
        #expect(rig.lookups.value == 0 && !rig.web.access.wanted)
        #expect(requests.queue.sync { requests.accepted }.isEmpty)

        // What the server's handler answers the user.
        let opened = Locked<NodeWire.Reply?>(nil)
        requests.queue.async { requests.webOpenTailnet(NodeWire.Request(id: "o", kind: "web.open", args: ["tailnet": .bool(true)])) { opened.value = $0 } }
        try #require(await eventually { opened.value != nil })
        let url = try #require(opened.value?.result?["url"]?.string, "\(String(describing: opened.value))")
        #expect(url.hasPrefix("http://\(Self.name):") && url.contains("/#pair="), "\(url)")
        #expect(opened.value?.result?["tailnet"]?.bool == true && opened.value?.result?["expiresIn"]?.int == 120)
        _ = try rig.web.access.tokens.issue(now: Date())
        let revoked = Locked<NodeWire.Reply?>(nil), access = try #require(requests.web)
        requests.queue.sync { requests.webRevoke(NodeWire.Request(id: "r", kind: "web.revoke"), web: access) { revoked.value = $0 } }
        #expect(revoked.value?.result?["tailnetRevoked"]?.int == 1 && revoked.value?.result?["revoked"]?.int == 0, "\(String(describing: revoked.value))")
        let web = rig.web
        try #require(await eventually { web.state == .off })

        // A server with no tailnet refuses it.
        requests.tailnet = nil
        let refused = Locked<NodeWire.Reply?>(nil)
        requests.queue.sync { requests.webOpenTailnet(NodeWire.Request(id: "n", kind: "web.open")) { refused.value = $0 } }
        #expect(refused.value?.error?.message.contains("only the user's node") == true, "\(String(describing: refused.value))")
    }
}

private extension TailnetWeb {
    func port(isOn: Bool) -> Bool {
        if case .on = state { return isOn }
        return !isOn
    }
}
