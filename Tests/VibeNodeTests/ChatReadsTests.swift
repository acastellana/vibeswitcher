import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The reads beside a session's chat (`ChatReads.swift`, 2026-11-21): `chat.image` serves the bytes of an image the
/// session's own chat shows, in parts, by its id alone, only as a PNG, JPEG, GIF or WebP its bytes agree with, never a
/// file a client names, never through a transcript outside the agents' folders; `session.usage` reads the session's
/// tokens and cost from its transcript. Each test has a scratch home (`ChatWorld`); each waits on the reply it checks.
struct ChatReadsTests {
    /// A PNG's signature, then `count` more bytes.
    static func png(_ count: Int) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0..<count).map { UInt8($0 % 251) })
    }

    /// The image ids the first event's items show: the prompt's, then the tool result's.
    static func imageIDs(_ client: Recorder) -> [String] {
        let items = client.events.first?["items"]?.array ?? []
        let prompts = items.flatMap { $0["images"]?.array ?? [] }
        let results = items.flatMap { $0["tools"]?.array ?? [] }.flatMap { $0["result"]?["images"]?.array ?? [] }
        return (prompts + results).compactMap { $0["id"]?.string }
    }

    /// Every part of image `id`, asked one after another as the page asks, joined.
    static func whole(_ world: ChatWorld, _ client: Recorder, session: String, id: String) async throws -> (Data, [NodeWire.Value]) {
        var data = Data()
        var replies: [NodeWire.Value] = []
        while true {
            let reply = try await world.request(client, "chat.image", ["session": .string(session), "id": .string(id), "offset": .int(data.count)])
            replies.append(reply)
            guard let part = reply["result"]?["data"]?.string.flatMap({ Data(base64Encoded: $0) }), let total = reply["result"]?["bytes"]?.int,
                  !part.isEmpty else { return (data, replies) }
            data += part
            if data.count >= total { return (data, replies) }
        }
    }

    @Test func anImageOfTheChatIsServedInPartsAsItsBytesSay() async throws {
        let world = try ChatWorld()
        let big = Self.png(500_000), small = Self.png(1_000)
        try world.append(ChatWorld.promptWithImage("u1", "What is this?", big))
        try world.append(ChatWorld.toolUse("a1", id: "t1", command: "screenshot"))
        try world.append(ChatWorld.toolResultWithImage("u2", id: "t1", small))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        let ids = Self.imageIDs(client)
        try #require(ids.count == 2, "\(ids)")

        let (bytes, replies) = try await Self.whole(world, client, session: world.session, id: ids[0])
        #expect(bytes == big)
        #expect(replies.count == 3, "500 KB in parts of 192 KB")
        for reply in replies {
            #expect(reply["result"]?["mediaType"] == .string("image/png") && reply["result"]?["bytes"] == .int(big.count))
            #expect(WireSchema.check(reply, as: "reply.chat.image") == nil, "\(WireSchema.check(reply, as: "reply.chat.image") ?? "")")
        }
        let (result, _) = try await Self.whole(world, client, session: world.session, id: ids[1])
        #expect(result == small)
        // A read is no event: the subscription's sequence is untouched.
        #expect(client.events.count == 1)
    }

    /// No client follows the chat: the store opens it for the read, as for `chat.page`.
    @Test func anImageIsServedWithNoSubscription() async throws {
        let world = try ChatWorld()
        let bytes = Self.png(2_000)
        try world.append(ChatWorld.promptWithImage("u1", "Look", bytes))
        let watcher = Recorder()
        try await world.subscribe(watcher, sub: "c1")
        let id = try #require(Self.imageIDs(watcher).first)
        let other = Recorder()
        let (data, _) = try await Self.whole(world, other, session: world.session, id: id)
        #expect(data == bytes)
    }

    /// The client names an id, and only an id the chat holds is an image: a path, inside the agents' folders or out of
    /// them, a traversal, another session's image id, all `gone`; a past-the-end offset is out of form.
    @Test func onlyAnIdTheChatHoldsIsServedNeverAPath() async throws {
        let world = try ChatWorld()
        try world.append(ChatWorld.promptWithImage("u1", "Look", Self.png(100)))
        // A real PNG on disk, beside the transcript and outside the agents' folders.
        let beside = world.transcript.deletingLastPathComponent().appendingPathComponent("shot.png")
        try Self.png(64).write(to: beside)
        let secret = world.home.appendingPathComponent("secret.png")
        try Self.png(64).write(to: secret)
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        let id = try #require(Self.imageIDs(client).first)
        for wanted in [beside.path, secret.path, "../../secret.png", "../shot.png", "shot.png", "/etc/passwd", id + "/../" + id, id + "x"] {
            let reply = try await world.request(client, "chat.image", ["session": .string(world.session), "id": .string(wanted)])
            #expect(reply["error"]?["code"] == .string("gone"), "\(wanted): \(reply)")
        }
        let past = try await world.request(client, "chat.image", ["session": .string(world.session), "id": .string(id), "offset": .int(108)])
        #expect(past["error"]?["code"] == .string("bad-args"), "\(past)")
        let negative = try await world.request(client, "chat.image", ["session": .string(world.session), "id": .string(id), "offset": .int(-1)])
        #expect(negative["error"]?["code"] == .string("bad-args"), "\(negative)")
        let missing = try await world.request(client, "chat.image", ["session": .string(world.session)])
        #expect(missing["error"]?["code"] == .string("bad-args"), "\(missing)")
        // Another session's chat doesn't hold it, and a session the node doesn't know is gone.
        var other = LiveWorld.session("pts/9")
        let otherTranscript = world.transcript.deletingLastPathComponent().appendingPathComponent("1f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f.jsonl")
        try Data((ChatWorld.prompt("u1", "Nothing to see") + "\n").utf8).write(to: otherTranscript)
        other.transcriptPath = otherTranscript.path
        world.sessions.send("local:pts/9", other)
        for session in ["local:pts/9", "local:pts/404"] {
            let reply = try await world.request(client, "chat.image", ["session": .string(session), "id": .string(id)])
            #expect(reply["error"]?["code"] == .string("gone"), "\(session): \(reply)")
        }
    }

    /// A session whose transcript is a link out of the agents' folders, or a file outside them, serves no image, though
    /// that file holds one.
    @Test func aTranscriptThroughALinkOrOutsideServesNothing() async throws {
        let world = try ChatWorld()
        let outside = world.home.appendingPathComponent("notes/elsewhere.jsonl")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((ChatWorld.promptWithImage("u1", "Look", Self.png(100)) + "\n").utf8).write(to: outside)
        // The id it would have, read from a session whose transcript holds the same line.
        try world.append(ChatWorld.promptWithImage("u1", "Look", Self.png(100)))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        let id = try #require(Self.imageIDs(client).first)
        let link = world.transcript.deletingLastPathComponent().appendingPathComponent("2f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for (tty, path) in [("pts/5", outside.path), ("pts/6", link.path)] {
            var session = LiveWorld.session(tty)
            session.transcriptPath = path
            world.sessions.send("local:\(tty)", session)
            let reply = try await world.request(client, "chat.image", ["session": .string("local:\(tty)"), "id": .string(id)])
            #expect(reply["error"]?["code"] == .string("gone"), "\(tty): \(reply)")
            let usage = try await world.request(client, "session.usage", ["session": .string("local:\(tty)")])
            #expect(usage["error"]?["code"] == .string("gone"), "\(tty): \(usage)")
        }
    }

    /// An image whose bytes aren't what it says (an SVG called a PNG), or aren't an image this page shows, is refused.
    @Test func anImageWhoseBytesDisagreeIsRefused() {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#.utf8)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])
        let cases: [(ChatImage, String?)] = [
            (ChatImage(id: "a", mediaType: "image/png", data: svg), "refused"),
            (ChatImage(id: "b", mediaType: "image/svg+xml", data: svg), "refused"),
            (ChatImage(id: "c", mediaType: "image/png", data: jpeg), "refused"),
            (ChatImage(id: "d", mediaType: "image/jpeg", data: jpeg), nil),
            (ChatImage(id: "e", mediaType: "image/webp", data: Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), nil),
            (ChatImage(id: "f", mediaType: "image/gif", data: Data("GIF89a..".utf8)), nil),
            (ChatImage(id: "g", mediaType: "image/png", data: Self.png(ChatImageBytes.most)), "refused"),
        ]
        for (image, code) in cases {
            switch ChatImageBytes.part(of: image, offset: 0) {
            case .value(let value):
                #expect(code == nil, "\(image.id) served")
                #expect(value["mediaType"] == .string(image.mediaType))
            case .refused(let failure):
                #expect(failure.code == code, "\(image.id): \(failure)")
            }
        }
        if case .refused(let failure) = ChatImageBytes.part(of: nil, offset: 0) { #expect(failure.code == "gone") } else { Issue.record("no image served") }
    }

    // MARK: Usage

    static func turn(_ uuid: String, prompt: String, reply: String, input: Int, cached: Int, output: Int, cost: Double?) -> [String] {
        var answer: [String: Any] = ["type": "assistant", "uuid": "a-" + uuid, "timestamp": ChatWorld.stamp,
                                     "message": ["id": "msg-" + uuid, "role": "assistant", "model": "claude-opus-5-5",
                                                 "content": [["type": "text", "text": reply]],
                                                 "usage": ["input_tokens": input, "cache_read_input_tokens": cached,
                                                           "cache_creation_input_tokens": 0, "output_tokens": output]]]
        if let cost { answer["costUSD"] = cost }
        return [ChatWorld.prompt(uuid, prompt), ChatWorld.line(answer)]
    }

    @Test func aSessionsUsageIsItsTranscriptsTokensAndCost() async throws {
        let world = try ChatWorld()
        try world.append(Self.turn("u1", prompt: "Fix it", reply: "Done", input: 10, cached: 1_000, output: 50, cost: 0.25)
                         + Self.turn("u2", prompt: "Again", reply: "Done again", input: 5, cached: 2_000, output: 20, cost: nil))
        let client = Recorder()
        let reply = try await world.request(client, "session.usage", ["session": .string(world.session)])
        #expect(WireSchema.check(reply, as: "reply.session.usage") == nil, "\(WireSchema.check(reply, as: "reply.session.usage") ?? "")")
        let result = try #require(reply["result"], "\(reply)")
        #expect(result["count"] == .int(2) && result["turns"]?.array?.count == 2 && result["partial"] == .bool(false))
        #expect(result["tokens"] == .object(["input": .int(3_015), "cached": .int(3_000), "output": .int(70)]), "\(result)")
        #expect(result["cost"] == .double(0.25) && result["costPartial"] == .bool(true), "\(result)")
        let gone = try await world.request(client, "session.usage", ["session": .string("local:pts/404")])
        #expect(gone["error"]?["code"] == .string("gone"))
        let bare = try await world.request(client, "session.usage", [:])
        #expect(bare["error"]?["code"] == .string("bad-args"))
    }

    /// A page's token that doesn't read gets nothing.
    @Test func aConnectionThatMayNotReadIsRefused() async throws {
        let world = try ChatWorld()
        let client = Recorder()
        for kind in ["chat.image", "session.usage"] {
            world.queue.sync {
                _ = world.hub.handle(NodeWire.Request(id: kind, kind: kind, args: ["session": .string(world.session), "id": .string("x")]),
                                     on: client, rights: [])
            }
        }
        #expect(client.messages.count == 2 && client.messages.allSatisfy { $0["error"]?["code"] == .string("voice") }, "\(client.messages)")
    }
}
