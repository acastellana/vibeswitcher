import Darwin
import Foundation
import Testing
@testable import VibeCore

/// `vibeswitcher-mcp --keeper`, as Claude Code runs it (see `MCPKeeper`): a tool server that stops is started again, and
/// the client goes on with no new initialize. The real binary on real pipes (`ScratchToolServer`, the keeper its
/// process), its builds the scripts standing in for one that MCPHandoverTests use; the relay's own rules in memory.
struct MCPKeeperTests {
    let scratch = Scratch()

    /// The keeper's one child, the tool server, once it runs: not `previous`.
    func child(of server: ScratchToolServer, not previous: pid_t? = nil) throws -> pid_t {
        var found: pid_t?
        _ = eventually {
            found = SessionStrays.children(of: server.process.processIdentifier).first { $0 != previous }
            return found != nil
        }
        return try #require(found, "the keeper runs no tool server; its stderr: \(server.log)")
    }

    func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
    }

    func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    // MARK: The real binary

    @Test func aKilledServerIsStartedAgainAndTheClientGoesOnWithNoNewInitialize() throws {
        let server = try ScratchToolServer(scratch, keeper: true)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize + [server.call(2, "build")])
        #expect(try server.tools(1) == ["build", "slow", "only-A"])
        let first = try child(of: server)
        #expect(try server.texts(2) == ["A \(first)"])

        // A call in hand when it dies: the ping after it is answered once the server has it (it reads in order).
        try server.send([server.call(3, "slow", ["seconds": 60]), ["jsonrpc": "2.0", "id": 4, "method": "ping"]])
        _ = try server.reply(4)
        #expect(kill(first, SIGKILL) == 0)
        let failed = try server.reply(3)
        let message = try #require((failed["error"] as? [String: Any])?["message"] as? String, "\(failed)")
        #expect(message.contains("stopped while this ran (it was killed by signal 9") && message.contains("started again"))

        // The next call is answered by a new server, the client having sent nothing but the call.
        try server.send([server.call(5, "build")])
        let second = try child(of: server, not: first)
        #expect(try server.texts(5) == ["A \(second)"])
        #expect(second != first && kill(first, 0) != 0)
        // The same keeper, on the same pipes; the replayed initialize's reply never reached the client, and the
        // client was told to ask for its tools again.
        #expect(server.process.isRunning)
        #expect(server.strayReplies.isEmpty, "\(server.strayReplies)")
        #expect(server.replyOrder == [0, 1, 2, 4, 3, 5])
        #expect(server.notifications == ["notifications/tools/list_changed"])
        try server.send([["jsonrpc": "2.0", "id": 6, "method": "tools/list"]])
        #expect(try server.tools(6) == ["build", "slow", "only-A"])

        // The restart is in the keeper's log, with how the server ended.
        let log = server.mcpLog(server.process.processIdentifier)
        #expect(log.contains("keeper: the tool server was killed by signal 9 (Killed: 9); starting it again (restart 1 of 5 within 60 s); 1 call in hand answered with an error"), "\(log)")
        #expect(log.contains("keeper: started the tool server again, pid \(second), the client's initialize replayed"), "\(log)")
    }

    @Test func aServerThatKeepsStoppingIsStartedAgainFiveTimesThenItsKeeperEnds() throws {
        let server = try ScratchToolServer(scratch, environment: ["VIBESWITCHER_MCP_TEST_EXIT": "3"], keeper: true)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        // Its first start and five more, a little later each time (3.75 s in all), then the keeper gives up.
        #expect(eventually(timeout: 60) { !server.process.isRunning }, "the keeper still runs; its stderr: \(server.log)")
        #expect(server.process.terminationStatus == 1)
        #expect(server.log.contains("vibeswitcher-mcp keeper: the tool server stopped 6 times within 60 s (last: it exited with status 3); not starting it again"),
                "\(server.log)")
        // Nothing hangs: the client's initialize got an error, not silence.
        #expect((try server.reply(0)["error"] as? [String: Any]) != nil)
        let log = server.mcpLog(server.process.processIdentifier)
        #expect(log.components(separatedBy: "; starting it again").count - 1 == 5, "\(log)")
        #expect(log.contains("restart 5 of 5 within 60 s"), "\(log)")
    }

    /// A new build takes over in the child, in place, as without a keeper; a restart after that starts the new build.
    @Test func aSwitchOfBuildsHappensInTheKeptServer() throws {
        let server = try ScratchToolServer(scratch, keeper: true)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize + [server.call(2, "build")])
        let first = try child(of: server)
        #expect(try server.texts(2) == ["A \(first)"])

        try server.install(build: "B")
        try server.send([server.call(3, "build")])
        #expect(try server.texts(3) == ["B \(first)"])
        #expect(server.log.contains("switched in place to the new build"))
        #expect(server.notifications == ["notifications/tools/list_changed"])
        try server.send([["jsonrpc": "2.0", "id": 4, "method": "tools/list"]])
        #expect(try server.tools(4) == ["build", "slow", "only-B"])

        #expect(kill(first, SIGKILL) == 0)
        // Asked once the new one runs: a call the keeper reads before it hears of the end is one in hand, and fails.
        let second = try child(of: server, not: first)
        try server.send([server.call(5, "build")])
        #expect(try server.texts(5) == ["B \(second)"])
        #expect(server.notifications == ["notifications/tools/list_changed", "notifications/tools/list_changed"])
    }

    @Test func theKeeperEndsWithItsClientAndTakesItsServerWithIt() throws {
        let server = try ScratchToolServer(scratch, keeper: true)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let kept = try child(of: server)
        server.closeInput()
        #expect(eventually { !server.process.isRunning })
        #expect(server.process.terminationStatus == 0)
        #expect(eventually { kill(kept, 0) != 0 })
        #expect(!server.mcpLog(server.process.processIdentifier).contains("; starting it again"))
    }

    /// The host's orphan sweep ends a tool server with SIGTERM: the keeper passes it on and ends with its server.
    @Test func aSigtermToTheKeeperEndsItsServerAndThenItself() throws {
        let server = try ScratchToolServer(scratch, keeper: true)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let kept = try child(of: server)
        #expect(kill(server.process.processIdentifier, SIGTERM) == 0)
        #expect(eventually { !server.process.isRunning })
        #expect(server.process.terminationStatus == 0)
        #expect(eventually { kill(kept, 0) != 0 })
        let log = server.mcpLog(server.process.processIdentifier)
        #expect(log.contains("keeper: stopping: signal 15") && !log.contains("; starting it again"), "\(log)")
    }

    // MARK: The relay's rules

    @Test func theRelayFailsWhatTheServerHadInHandAndReplaysTheHandshake() throws {
        var relay = MCPKeeper.Relay()
        #expect(relay.replay().isEmpty, "nothing to replay before the client initializes")
        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                         "params": ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code"]]]
        relay.fromClient(try line(initialize))
        #expect(relay.fromChild(try line(["jsonrpc": "2.0", "id": 0, "result": [String: Any]()])))
        relay.fromClient(try line(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        // A number and a string that read alike are two requests.
        relay.fromClient(try line(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "merge"]]))
        relay.fromClient(try line(["jsonrpc": "2.0", "id": "7", "method": "tools/call", "params": ["name": "status"]]))
        relay.fromClient(try line(["jsonrpc": "2.0", "id": 8, "method": "ping"]))
        // Notifications from the server pass and change nothing; an answered request leaves the hand.
        #expect(relay.fromChild(try line(["jsonrpc": "2.0", "method": "notifications/progress", "params": ["progressToken": 7]])))
        #expect(relay.fromChild(try line(["jsonrpc": "2.0", "id": 8, "result": [String: Any]()])))
        #expect(relay.pending == ["n:7", "s:7"])

        let errors = relay.ended("was killed by signal 9 (Killed: 9)").compactMap(object)
        #expect(errors.count == 2)
        #expect(errors.map { "\($0["id"]!)" } == ["7", "7"] && errors[0]["id"] is NSNumber && errors[1]["id"] is String)
        #expect(errors.allSatisfy { (($0["error"] as? [String: Any])?["message"] as? String)?.contains("killed by signal 9") == true })
        #expect(relay.pending.isEmpty)

        let replay = relay.replay().compactMap(object)
        #expect(replay.map { $0["method"] as? String } == ["initialize", "notifications/initialized"])
        let replayID = try #require(replay[0]["id"] as? String)
        #expect(replay[0]["params"] as? NSDictionary == initialize["params"] as? NSDictionary)
        // The new server's reply to it is swallowed, once; the client's own replies pass.
        #expect(!relay.fromChild(try line(["jsonrpc": "2.0", "id": replayID, "result": [String: Any]()])))
        #expect(relay.fromChild(try line(["jsonrpc": "2.0", "id": replayID, "result": [String: Any]()])))
        #expect(relay.toolsMayHaveChanged.flatMap(object)?["method"] as? String == "notifications/tools/list_changed")
        // A second replay has an id of its own.
        #expect(relay.replay().compactMap(object).first?["id"] as? String != replayID)
    }

    @Test func restartsAreLaterEachTimeAndAtMostFiveAMinute() {
        var restarts = MCPKeeper.Restarts(limit: 5, window: 60)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let delays = (0..<5).map { restarts.spend(at: start.addingTimeInterval(Double($0))) }
        #expect(delays == [0, 0.25, 0.5, 1, 2])
        #expect(restarts.spend(at: start.addingTimeInterval(10)) == nil)
        #expect(restarts.recent(at: start.addingTimeInterval(10)) == 5)
        // A minute after the first, one is left again.
        #expect(restarts.spend(at: start.addingTimeInterval(60.5)) != nil)
    }

    @Test func aServersEndInWords() {
        #expect(MCPKeeper.describe(status: 3 << 8) == "exited with status 3")
        #expect(MCPKeeper.describe(status: SIGKILL) == "was killed by signal 9 (Killed: 9)")
    }
}
