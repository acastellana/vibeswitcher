import Foundation
import Testing
import VibeNode

/// The server's protocol on the wire (the engine plan's "The protocol", EN-D2): JSON lines, rule 3's unknown fields,
/// the 1 MiB limit. The Mac runs these.
struct NodeWireTests {
    @Test func aRequestAndItsReplyRoundTrip() throws {
        let request = NodeWire.Request(id: "7", kind: "answer", args: ["card": .string("local:card:x"), "text": .string("yes\nand more"),
                                                                      "n": .int(3), "on": .bool(true), "list": .array([.null, .double(1.5)])],
                                       action: UUID().uuidString.lowercased(), must: true)
        let line = NodeWire.line(request)
        // One line: the newline only at its end, a newline in a value escaped.
        #expect(line.last == UInt8(ascii: "\n") && line.dropLast().contains(UInt8(ascii: "\n")) == false)
        #expect(NodeWire.decode(NodeWire.Request.self, line.dropLast()) == request)

        let reply = NodeWire.Reply(re: "7", result: .object(["outcome": .string("answered"), "at": .date(Date(timeIntervalSince1970: 1))]))
        #expect(NodeWire.decode(NodeWire.Reply.self, NodeWire.line(reply).dropLast()) == reply)
        let failed = NodeWire.Reply(re: "8", error: .init(.voice, "not the user's voice: its cgroup is a user unit"))
        let decoded = try #require(NodeWire.decode(NodeWire.Reply.self, NodeWire.line(failed).dropLast()))
        #expect(decoded == failed && decoded.ok == false && decoded.error?.code == "voice")
        // Lines cut out of bytes as they come, in pieces.
        var lines = NodeWire.Lines()
        let both = NodeWire.line(request) + NodeWire.line(reply)
        #expect(lines.append(both.prefix(10)).isEmpty)
        #expect(lines.append(both.dropFirst(10)).count == 2)
    }

    @Test func anUnknownFieldIsIgnored() throws {
        let line = Data(#"{"v":1,"id":"a","kind":"status","args":{},"later":{"nested":[1,2]},"flag":true}"#.utf8)
        let request = try #require(NodeWire.decode(NodeWire.Request.self, line))
        #expect(request.kind == "status" && request.id == "a" && request.must == nil)
        let hello = Data(#"{"v":1,"kind":"hello","node":"local","epoch":"e","server":{"commit":"c","startedAt":"s","pid":3,"new":1},"host":{"startedAt":null},"kinds":["status"],"peer":{"voice":"user"},"rule":"weaker","stage3":"x"}"#.utf8)
        let decoded = try #require(NodeWire.decode(NodeWire.Hello.self, hello))
        #expect(decoded.server.pid == 3 && decoded.kinds == ["status"] && decoded.rule == "weaker")
    }

    @Test func aLineOverOneMebibyteIsRefused() {
        var lines = NodeWire.Lines()
        // Exactly the limit is a line; one byte more, with no newline yet, is refused.
        let limit = Data(repeating: UInt8(ascii: "a"), count: NodeWire.maxLine)
        #expect(lines.append(limit + Data("\n".utf8)).count == 1)
        #expect(!lines.tooLong)
        #expect(lines.append(limit).isEmpty && !lines.tooLong)
        #expect(lines.append(Data("b".utf8)).isEmpty)
        #expect(lines.tooLong)
        // Nothing more is taken once refused, a newline included.
        #expect(lines.append(Data("\n{}\n".utf8)).isEmpty)
        // A long line ending in one piece is refused too.
        var whole = NodeWire.Lines()
        #expect(whole.append(Data(repeating: UInt8(ascii: "a"), count: NodeWire.maxLine + 1) + Data("\n".utf8)).isEmpty)
        #expect(whole.tooLong)
    }
}
