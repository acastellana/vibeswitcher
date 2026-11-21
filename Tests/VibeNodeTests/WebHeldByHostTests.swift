import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// H1 (docs/process/v2-h1-plan.md; the security architecture's S11 item 32): the session host holds the web's
/// listening socket while the web is on, and the server only accepts on it. Between two servers (a restart, a
/// handover) no other process can bind the port, and a page's connection made meanwhile is answered by the next
/// server; `web --revoke` frees it; a server the host refuses never binds one itself.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct WebHeldByHostTests {
    private let scratch = Scratch()

    /// A bind of `address`:`port` by this process, as a squatter would try it (`SO_REUSEADDR`, which takes a port in
    /// TIME_WAIT but never one a socket listens on): nil when it was refused, else the errno-free success, closed again.
    private func squat(_ address: String, _ port: UInt16) -> Bool {
        switch Platform.TCP.listen(family: .ipv4, address: address, port: port, backlog: 1) {
        case .success(let fd):
            Sys.close(fd)
            return true
        case .failure:
            return false
        }
    }

    /// `web.open`, and a page paired with its code, so a token is alive at rest (a code is the running server's
    /// alone: the next server would find the web off): the port.
    private func paired(_ node: ScratchNode) throws -> UInt16 {
        let opened = try LiveScratch.open(node)
        let page = try TermPage(port: opened.port)
        _ = try page.send("auth", ["pair": .string(opened.code), "client": .string("test")])
        let hello = try page.next()?.json
        try #require(hello?["kind"]?.string == "hello", "no hello: \(String(describing: hello))")
        return opened.port
    }

    /// The server `old` gone (reaped by the host), before the host starts the next.
    private func gone(_ old: pid_t) async -> Bool {
        await eventually(timeout: 60) { Platform.Processes.link(old) == nil }
    }

    /// A GET of `/` on `port`, sent now: the head of the answer, once a server accepts.
    private func get(_ port: UInt16) throws -> WebTestClient {
        let client = try WebTestClient(port: port)
        #expect(client.send("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"))
        return client
    }

    @Test func thePortIsHeldAcrossAServerRestartAndTheNextServerAnswers() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let port = try paired(node)
        #expect(node.said.contains("web listener loopback bound on 127.0.0.1:\(port), held for the server"), "\(node.said)")
        let old = try #require(node.serverPID)
        kill(old, SIGKILL)
        try #require(await gone(old), "\(node.said)")
        // Between the two servers (the host starts the next 1 s after the last ended): nothing else binds it, on its
        // address or the wildcard.
        #expect(!squat("127.0.0.1", port) && !squat("0.0.0.0", port))
        // A page's request made meanwhile waits in the host's socket, and the next server answers it.
        let waiting = try get(port)
        let hello = try await node.restartServer(after: old)
        #expect(hello.server.pid != old)
        let head = try #require(waiting.response()?.head, "no answer: \(node.said)")
        #expect(head.hasPrefix("HTTP/1.1 "), "\(head)")
        let status = try await node.statusJSON()
        #expect((status["web"] as? [String: Any])?["port"] as? Int == Int(port), "\(status["web"] ?? "none")")
    }

    @Test func thePortIsHeldAcrossAHandover() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let port = try paired(node)
        try await node.handOver()
        // Said once the new image has taken its server child, which may be after its "took over".
        #expect(await eventually(timeout: 60) { node.said.contains("web listener loopback 127.0.0.1:\(port) held on across the handover") }, "\(node.said)")
        // The new image holds it: with the server gone, still nobody else's.
        let old = try #require(node.serverPID)
        kill(old, SIGKILL)
        try #require(await gone(old), "\(node.said)")
        #expect(!squat("127.0.0.1", port) && !squat("0.0.0.0", port))
        let waiting = try get(port)
        try await node.restartServer(after: old)
        let head = try #require(waiting.response()?.head, "no answer: \(node.said)")
        #expect(head.hasPrefix("HTTP/1.1 "), "\(head)")
    }

    @Test func revokeFreesThePortAndTheNextWebBindsAgain() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let opened = try LiveScratch.open(node)
        #expect(!squat("127.0.0.1", opened.port))
        let revoked = try await node.runOnTerminal(["web", "--revoke"])
        #expect(revoked.status == 0, "\(revoked.output)\n\(node.said)")
        #expect(await eventually(timeout: 60) { node.said.contains("web listener loopback 127.0.0.1:\(opened.port) closed: the web went off") }, "\(node.said)")
        #expect(squat("127.0.0.1", opened.port), "the port is free once the web is off")
        let again = try LiveScratch.open(node)
        #expect(node.said.contains("web listener loopback bound on 127.0.0.1:\(again.port), held for the server"), "\(node.said)")
        #expect(!squat("127.0.0.1", again.port))
    }
}
