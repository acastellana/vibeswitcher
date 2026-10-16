import Foundation
import Testing
@testable import VibeCore

struct MCPServerTests {
    final class Echo: MCPToolset {
        var tools: [MCPToolInfo] {
            [MCPToolInfo(name: "echo", description: "Says it back", properties: ["text": .init(type: "string", description: "What to say")], required: ["text"])]
        }
        func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult {
            guard name == "echo", let text = arguments["text"] as? String else { return MCPToolResult(text: "bad call", isError: true) }
            return MCPToolResult(text: "echo: \(text)")
        }
    }

    func send(_ server: MCPServer, _ object: [String: Any]) throws -> [String: Any]? {
        guard let reply = server.handle(try JSONSerialization.data(withJSONObject: object)) else { return nil }
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    @Test func handshakeListAndCall() throws {
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: Echo())
        let initialized = try #require(try send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                        "params": ["protocolVersion": "2025-06-18", "capabilities": [:]]]))
        let result = try #require(initialized["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "vibeswitcher")
        #expect(result["capabilities"] as? [String: Any] != nil)
        #expect(try send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)

        let list = try #require(try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "echo")
        let schema = try #require(tools.first?["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["text"])

        let call = try #require(try send(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "hi"]]]))
        let content = try #require((call["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "echo: hi")
        #expect((call["result"] as? [String: Any])?["isError"] as? Bool == false)
        #expect(call["id"] as? Int == 3)
    }

    @Test func errorsAreReportedNotCrashed() throws {
        let server = MCPServer(name: "v", version: "1", toolset: Echo())
        let bad = try #require(try send(server, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "echo", "arguments": [:]]]))
        #expect((bad["result"] as? [String: Any])?["isError"] as? Bool == true)
        let unknown = try #require(try send(server, ["jsonrpc": "2.0", "id": "x", "method": "nope"]))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(unknown["id"] as? String == "x")
        let garbage = try #require(server.handle(Data("not json".utf8)).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((garbage["error"] as? [String: Any])?["code"] as? Int == -32700)
        let ping = try #require(try send(server, ["jsonrpc": "2.0", "id": 5, "method": "ping"]))
        #expect(ping["result"] as? [String: Any] != nil)
    }
}
