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

    /// Review Focus 7: JSON for a terminal escapes what `ConfigSeal.inert` would replace (C1 controls, DEL, bidi and
    /// other format characters, past U+FFFF too) and means the same JSON.
    @Test func printableJSONEscapesWhatATerminalWouldActOn() throws {
        let text = "a\u{1b}[31m b\u{9b}31m c\u{202e}d \u{7f} e\u{2066}\u{200b}\u{feff}\u{2028} f\u{e0001}\u{f0000} é漢🙂/"
        let value = NodeWire.Value.object(["k": .string(text), "list": .array([.string("\u{85}")])])
        let line = NodeWire.printable(NodeWire.line(value))
        #expect(line.last == UInt8(ascii: "\n"))
        let printed = String(decoding: line.dropLast(), as: UTF8.self)
        let raw = printed.unicodeScalars.filter { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || (0x200B...0x200F).contains($0.value)
            || (0x2028...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) || $0.value == 0xFEFF || $0.value >= 0xE0000 }
        #expect(raw.isEmpty, "\(raw.map { String($0.value, radix: 16) })")
        #expect(printed.contains("é漢🙂/") && printed.contains(#"\u009b"#) && printed.contains(#"\udb40\udc01"#), "\(printed)")
        #expect(NodeWire.decode(NodeWire.Value.self, line.dropLast()) == value)
        #expect(NodeWire.printable(Data("{}".utf8)) == Data("{}".utf8))
    }

    @Test func anUnknownFieldIsIgnored() throws {
        let line = Data(#"{"v":1,"id":"a","kind":"status","args":{},"later":{"nested":[1,2]},"flag":true}"#.utf8)
        let request = try #require(NodeWire.decode(NodeWire.Request.self, line))
        #expect(request.kind == "status" && request.id == "a" && request.must == nil)
        let hello = Data(#"{"v":1,"kind":"hello","node":"local","epoch":"e","server":{"commit":"c","startedAt":"s","pid":3,"new":1},"host":{"startedAt":null},"kinds":["status"],"peer":{"voice":"user"},"rule":"weaker","stage3":"x"}"#.utf8)
        let decoded = try #require(NodeWire.decode(NodeWire.Hello.self, hello))
        #expect(decoded.server.pid == 3 && decoded.kinds == ["status"] && decoded.rule == "weaker")
    }

    /// The live protocol's kinds (the live wire contract, W0): named with the voice each needs, and taken by no server
    /// until the integration task that wires each (I1 to I4), so a server answers them `unknown-kind` as before.
    /// The live protocol's kinds, each with its voice; slice 1's (I1) and the drafts (I3) taken, the others not yet.
    @Test func theLiveKindsAreNamedAndSliceOnesTaken() {
        let live: [String: NodeWire.Voice] = [
            "subscribe": .anyone, "unsubscribe": .anyone, "chat.page": .anyone,
            "draft": .webDraft, "draft.clear": .webDraft,
            "web.open": .user, "web.revoke": .user,
            "term.open": .webTerminal, "term.close": .webTerminal,
        ]
        // Slice 1's (I1), slice 2's `chat.page` (I2), and slice 3's drafts (I3).
        let taken: Set = ["subscribe", "unsubscribe", "web.open", "web.revoke", "chat.page", "draft", "draft.clear"]
        for (kind, voice) in live {
            #expect(NodeWire.kinds[kind] == voice, "\(kind)")
            #expect(NodeWire.taken.contains(kind) == taken.contains(kind), "\(kind)")
        }
        // What a server takes is a part of what the protocol names.
        #expect(Set(NodeWire.taken).isSubset(of: Set(NodeWire.kinds.keys)))
    }

    /// Rule 3: a `hello` from before `auth` and `assets`, and a `bye` from before `code`, still decode; a `hello` and a
    /// `bye` with them round-trip, and without them write neither field.
    @Test func anOlderHelloStillDecodes() throws {
        let older = Data(#"{"v":1,"kind":"hello","node":"local","epoch":"e","server":{"commit":"c","startedAt":"s","pid":3},"host":{"startedAt":null},"kinds":["status"],"peer":{"voice":"user"},"rule":"systemd"}"#.utf8)
        let hello = try #require(NodeWire.decode(NodeWire.Hello.self, older))
        #expect(hello.auth == nil && hello.assets == nil)
        let bye = try #require(NodeWire.decode(NodeWire.Bye.self, Data(#"{"v":1,"kind":"bye","reason":"stopping"}"#.utf8)))
        #expect(bye.code == nil && bye.reason == "stopping")

        let web = NodeWire.Hello(node: "local", epoch: "e", server: .init(commit: "c", startedAt: "s", pid: 3), host: .init(startedAt: nil, notes: nil),
                                 kinds: ["status", "subscribe"], peer: .init(voice: "other", why: "a web client"), rule: "systemd",
                                 auth: .object(["rights": .array([.string("read"), .string("draft")]), "expiresAt": .string("2026-11-18T09:14:03.120Z")]),
                                 assets: "9f2c61d0")
        #expect(NodeWire.decode(NodeWire.Hello.self, NodeWire.line(web).dropLast()) == web)
        let revoked = NodeWire.Bye(reason: "this page's access was revoked", code: "revoked")
        #expect(NodeWire.decode(NodeWire.Bye.self, NodeWire.line(revoked).dropLast()) == revoked)
        // On the Unix socket nothing changes: no `auth`, `assets` or `code` field is written.
        let plain = String(decoding: NodeWire.line(NodeWire.Bye(reason: "stopping")), as: UTF8.self)
        #expect(!plain.contains("\"code\""), "\(plain)")
        var unix = web
        unix.auth = nil
        unix.assets = nil
        let line = String(decoding: NodeWire.line(unix), as: UTF8.self)
        #expect(!line.contains("\"auth\"") && !line.contains("\"assets\""), "\(line)")
    }

    /// A kind no server takes yet is still classified: `draft` (a web client's) and `web.open` (the user's voice) change
    /// state, so the weaker rule's terminal check (`Voice.handsRefusal`) asks them when they are taken.
    @Test func aKindNobodyTakesStillChangesState() {
        #expect(NodeWire.changesState("draft"))
        #expect(NodeWire.changesState("draft.clear"))
        #expect(NodeWire.changesState("web.open"))
        #expect(NodeWire.changesState("web.revoke"))
        #expect(NodeWire.changesState("term.open"))
        #expect(!NodeWire.changesState("subscribe") && !NodeWire.changesState("unsubscribe") && !NodeWire.changesState("chat.page"))
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
