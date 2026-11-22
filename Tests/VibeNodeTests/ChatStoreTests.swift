import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A session's chat on the live wire (the live plan's B4, the live wire contract's §4 and §6): its transcript read into
/// wire items, the items' changes sent as ops (`add`, `text` for a reply that only grew, `set`, `remove`), the newest
/// 200 first and older ones paged, a resume answered from the last 512 ops, a restart answered by a `tail` from the
/// client's last item, and a stream nobody follows dropped after a minute. Each test has a scratch home whose
/// `.claude/projects` holds the transcript; the hub writes to a recording transport; nothing is slept on: each waits on
/// the event it checks.
struct ChatStoreTests {
    // MARK: Ops

    @Test func aNewEntryIsAnAdd() async throws {
        let world = try ChatWorld()
        try world.append(ChatWorld.prompt("u1", "Fix the login test"))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        try world.append(ChatWorld.reply("a1", "I'll start by reading the test."))
        try await client.waitFor(events: 2)

        let delta = client.events[1]
        #expect(delta["kind"] == .string("delta") && delta["sub"] == .string("c1"))
        #expect(delta["prev"] == client.events[0]["seq"] && delta["seq"]?.int == (client.events[0]["seq"]?.int ?? -9) + 1)
        let ops = try #require(delta["ops"]?.array)
        try #require(ops.count == 1, "\(ops)")
        #expect(ops[0]["op"] == .string("add"))
        #expect(ops[0]["item"]?["id"] == .string("a1.0") && ops[0]["item"]?["type"] == .string("reply"))
        #expect(ops[0]["item"]?["text"] == .string("I'll start by reading the test."))
        #expect(delta["changes"] == nil, "a chat's delta carries ops, not changes")
        #expect(WireSchema.check(delta, as: "delta.chat") == nil)
    }

    /// The transcript rewritten (a new file at the path) with the reply's text longer: only what was appended goes, at
    /// the old text's length.
    @Test func aGrowingReplyIsSentAsAppendedText() async throws {
        let world = try ChatWorld()
        try world.append(ChatWorld.prompt("u1", "Why does it fail?"))
        try world.append(ChatWorld.reply("a1", "It reads"))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        try world.replace(with: [ChatWorld.prompt("u1", "Why does it fail?"), ChatWorld.reply("a1", "It reads the token from the wrong header.")])
        try await client.waitFor(events: 2)

        let ops = try #require(client.events[1]["ops"]?.array)
        #expect(ops == [.object(["op": .string("text"), "id": .string("a1.0"), "at": .int(8),
                                 "append": .string(" the token from the wrong header.")])])
        // The client's text, appended to, is the server's.
        let held = try #require(world.queue.sync { world.chats.holds(world.session) ? world.stream?.items.last?.value["text"] : nil })
        #expect(held == .string("It reads the token from the wrong header."))
    }

    /// Text that grows by astral characters (a surrogate pair each in UTF-16) and by a joiner that makes a new grapheme of
    /// the old last one: `at` counts UTF-16 code units, and the append never starts with half a pair.
    @Test func anAppendNeverCutsASurrogatePair() {
        let cases: [(String, String)] = [("ok 😀", "ok 😀😀 more"), ("👩", "👩\u{200D}💻 at work"), ("e", "e\u{301}"), ("", "𝄞")]
        for (old, new) in cases {
            let made = ChatStream.appended(ChatWorld.replyValue("r", old), ChatWorld.replyValue("r", new))
            let grown = try? #require(made, "\(old) → \(new) is an append")
            guard let grown else { continue }
            #expect(grown.at == old.utf16.count, "\(old): at \(grown.at)")
            if let first = grown.append.utf16.first { #expect(!UTF16.isTrailSurrogate(first), "\(old) → \(new) starts inside a pair") }
            // Applied as a client applies it, in UTF-16: the new text, exactly.
            #expect(Array(old.utf16) + Array(grown.append.utf16) == Array(new.utf16))
        }
    }

    @Test func aChangeThatIsntAnAppendIsASet() {
        // Text that changed but didn't only grow, and a field beside the text that changed: each a `set`.
        let rewritten = ChatStream.ops(from: [ChatStream.Item(id: "r", value: ChatWorld.replyValue("r", "It reads the header"))],
                                       to: [("r", ChatWorld.replyValue("r", "It read the cookie"))])
        #expect(rewritten.map(\.value) == [.object(["op": .string("set"), "item": ChatWorld.replyValue("r", "It read the cookie")])])
        let steered = ChatWorld.value(prompt: "Go", steered: true)
        let moved = ChatStream.ops(from: [ChatStream.Item(id: "p", value: ChatWorld.value(prompt: "Go", steered: false))], to: [("p", steered)])
        #expect(moved.map(\.value) == [.object(["op": .string("set"), "item": steered])])
        // An item out of place (not at the end): what follows it is removed and added again, in order.
        let a = ChatWorld.replyValue("a", "A"), b = ChatWorld.replyValue("b", "B"), c = ChatWorld.replyValue("c", "C")
        let inserted = ChatStream.ops(from: [.init(id: "a", value: a), .init(id: "c", value: c)], to: [("a", a), ("b", b), ("c", c)])
        #expect(inserted.map(\.value) == [.object(["op": .string("remove"), "id": .string("c")]),
                                          .object(["op": .string("add"), "item": b]), .object(["op": .string("add"), "item": c])])
        // An item gone is a remove; nothing changed is no op.
        #expect(ChatStream.ops(from: [.init(id: "a", value: a), .init(id: "c", value: c)], to: [("a", a)]).map(\.value)
                == [.object(["op": .string("remove"), "id": .string("c")])])
        #expect(ChatStream.ops(from: [.init(id: "a", value: a)], to: [("a", a)]).isEmpty)
    }

    /// A tool's result arriving later in the transcript replaces its run whole: one `set` of the `tools` item.
    @Test func aToolsResultIsASetOfItsRun() async throws {
        let world = try ChatWorld()
        try world.append(ChatWorld.prompt("u1", "List the tests"))
        try world.append(ChatWorld.toolUse("a1", id: "t1", command: "ls Tests"))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        let first = try #require(client.events[0]["items"]?.array?.last)
        #expect(first["id"] == .string("tools:t1") && first["tools"]?.array?.first?["result"] == .null)
        try world.append(ChatWorld.toolResult("u2", id: "t1", output: "LoginTests.swift"))
        try await client.waitFor(events: 2)

        let ops = try #require(client.events[1]["ops"]?.array)
        try #require(ops.count == 1, "\(ops)")
        #expect(ops[0]["op"] == .string("set") && ops[0]["item"]?["id"] == .string("tools:t1"))
        #expect(ops[0]["item"]?["tools"]?.array?.first?["result"]?["output"] == .string("LoginTests.swift"))
        #expect(ops[0]["item"]?["summary"] == .string(ChatTimeline.summary([ChatTool(id: "t1", name: "Bash", title: "", detail: .command("ls Tests"),
                                                                                     at: nil, result: nil)])))
        // A second tool joins the run: the run again, whole.
        try world.append(ChatWorld.toolUse("a2", id: "t2", command: "swift test"))
        try await client.waitFor(events: 3)
        let second = try #require(client.events[2]["ops"]?.array)
        #expect(second.count == 1 && second[0]["op"] == .string("set") && second[0]["item"]?["tools"]?.array?.count == 2, "\(second)")
    }

    // MARK: Snapshots and pages

    @Test func theSnapshotIsTheNewest200() async throws {
        let world = try ChatWorld()
        try world.append((0..<450).map { ChatWorld.reply("a\($0)", "Reply \($0)") })
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        let snapshot = client.events[0]
        let items = try #require(snapshot["items"]?.array)
        #expect(items.count == 200)
        #expect(items.first?["id"] == .string("a250.0") && items.last?["id"] == .string("a449.0"))
        #expect(snapshot["more"] == .bool(true) && snapshot["after"] == .null)
        #expect(snapshot["collection"] == .string("chat") && snapshot["key"] == .string(world.session))
        #expect(WireSchema.check(snapshot, as: "snapshot") == nil)
        // A limit asked for is kept to 500; a chat shorter than it is whole, with nothing more.
        let wide = Recorder()
        try await world.subscribe(wide, sub: "c2", extra: ["limit": .int(10_000)])
        #expect(wide.events[0]["items"]?.array?.count == 450 && wide.events[0]["more"] == .bool(false))
    }

    @Test func aPageIsTheItemsJustBefore() async throws {
        let world = try ChatWorld()
        try world.append((0..<450).map { ChatWorld.reply("a\($0)", "Reply \($0)") })
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        let page = try await world.request(client, "chat.page", ["session": .string(world.session), "before": .string("a250.0"),
                                                                 "limit": .int(200)])
        let items = try #require(page["result"]?["items"]?.array, "\(page)")
        #expect(items.count == 200 && items.first?["id"] == .string("a50.0") && items.last?["id"] == .string("a249.0"))
        #expect(page["result"]?["more"] == .bool(true))
        #expect(WireSchema.check(page, as: "reply.chat.page") == nil)
        let last = try await world.request(client, "chat.page", ["session": .string(world.session), "before": .string("a50.0")])
        #expect(last["result"]?["items"]?.array?.count == 50 && last["result"]?["more"] == .bool(false))
        // An item the chat doesn't have, and a session with no transcript.
        let unknown = try await world.request(client, "chat.page", ["session": .string(world.session), "before": .string("nope")])
        #expect(unknown["error"]?["code"] == .string("bad-args"))
        let gone = try await world.request(client, "chat.page", ["session": .string("local:pts/77"), "before": .string("a1.0")])
        #expect(gone["error"]?["code"] == .string("gone"))
        // A page is no event: the subscription's sequence is untouched.
        #expect(client.events.count == 1)
    }

    // MARK: Resume

    @Test func aResumeInTheSameEpochGetsTheOpsSince() async throws {
        let world = try ChatWorld()
        try world.append(ChatWorld.prompt("u1", "Go"))
        let first = Recorder()
        try await world.subscribe(first, sub: "c1")
        let held = try #require(first.events[0]["seq"]?.int)
        world.queue.sync { world.hub.closed(first) }
        try world.append(ChatWorld.reply("a1", "One"))
        try world.append(ChatWorld.reply("a2", "Two"))
        try await world.waitForItems(3)

        let again = Recorder()
        try await world.subscribe(again, sub: "c1", extra: ["since": .object(["epoch": .string(world.hub.epoch), "seq": .int(held)]),
                                                           "after": .string("u1")])
        #expect(again.messages.first?["result"]?["mode"] == .string("resume"))
        try await again.waitFor(events: 1)
        let delta = again.events[0]
        #expect(delta["kind"] == .string("delta") && delta["prev"] == .int(held))
        #expect(delta["ops"]?.array?.compactMap { $0["item"]?["id"]?.string } == ["a1.0", "a2.0"])
    }

    /// A restart forgets every `seq` (a new epoch): the client sends its last item's id, and gets that item as it is now
    /// and what followed it, a `tail`; nothing lost, nothing twice.
    @Test func aChatResumesByItsLastItemAcrossARestart() async throws {
        let world = try ChatWorld()
        try world.append([ChatWorld.prompt("u1", "Go"), ChatWorld.toolUse("a1", id: "t1", command: "make")])
        let before = Recorder()
        try await world.subscribe(before, sub: "c1")
        let heldItems = try #require(before.events[0]["items"]?.array)
        let held = try #require(heldItems.last?["id"]?.string)
        #expect(held == "tools:t1")

        // The server restarts: a new hub, a new store, a new epoch. Meanwhile the tool's result came, and a reply.
        let restarted = try ChatWorld(after: world)
        try restarted.append([ChatWorld.toolResult("u2", id: "t1", output: "built"), ChatWorld.reply("a2", "It builds.")])
        let after = Recorder()
        try await restarted.subscribe(after, sub: "c1", extra: ["since": .object(["epoch": .string(world.hub.epoch), "seq": .int(0)]),
                                                               "after": .string(held)])
        #expect(after.messages.first?["result"]?["mode"] == .string("tail"))
        let tail = after.events[0]
        #expect(tail["after"] == .string(held) && tail["more"] == .bool(true) && tail["epoch"] == .string(restarted.hub.epoch))
        let items = try #require(tail["items"]?.array)
        #expect(items.compactMap { $0["id"]?.string } == ["tools:t1", "a2.0"])
        #expect(items[0]["tools"]?.array?.first?["result"]?["output"] == .string("built"), "the item `after`, as it is now")
        // Applied as the contract's client applies a tail: every item before `after`, then the tail's.
        let kept = heldItems.prefix { $0["id"]?.string != held }
        #expect((kept + items).compactMap { $0["id"]?.string } == ["u1", "tools:t1", "a2.0"])
        // An `after` the chat doesn't have: a whole snapshot, `after` null.
        let lost = Recorder()
        try await restarted.subscribe(lost, sub: "c2", extra: ["after": .string("never-seen")])
        #expect(lost.messages.first?["result"]?["mode"] == .string("snapshot") && lost.events[0]["after"] == .null)
    }

    /// A delta folded for a client that couldn't write: its ops in order, consecutive `text` ops of one item joined; and
    /// a client so late that the stream forgot its ops gets the newest items again.
    @Test func aFoldedChatDeltaJoinsItsTextOps() throws {
        let stream = ChatStream(session: "s", opsKept: 4)
        stream.take([("r", ChatWorld.replyValue("r", "A"))])
        stream.take([("r", ChatWorld.replyValue("r", "AB"))])
        stream.take([("r", ChatWorld.replyValue("r", "ABC")), ("x", ChatWorld.replyValue("x", "X"))])
        stream.take([("r", ChatWorld.replyValue("r", "ABC")), ("x", ChatWorld.replyValue("x", "XY"))])
        let range = try #require(stream.changes(since: 0))
        #expect(range.prev == 0 && range.seq == 4)
        #expect(range.ops == [.object(["op": .string("text"), "id": .string("r"), "at": .int(1), "append": .string("BC")]),
                              .object(["op": .string("add"), "item": ChatWorld.replyValue("x", "X")]),
                              .object(["op": .string("text"), "id": .string("x"), "at": .int(1), "append": .string("Y")])])
        stream.take([("r", ChatWorld.replyValue("r", "ABCD")), ("x", ChatWorld.replyValue("x", "XY"))])
        #expect(stream.changes(since: 0) == nil, "the first op is forgotten (4 kept)")
        #expect(stream.changes(since: 1)?.ops.count == 4, "text r, add x, text x, text r: only consecutive ones join")
        #expect(stream.changes(since: 6) == nil, "a seq ahead of the stream")
    }

    // MARK: Lifetime

    @Test func aStreamNobodyFollowsIsDroppedAfter60s() async throws {
        let time = DrivenTime()
        let clock = time.clock()
        let world = try ChatWorld(now: { time.now })
        world.chats.start(clock: clock)
        try world.append(ChatWorld.prompt("u1", "Go"))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        let seq = try #require(client.events[0]["seq"]?.int)
        time.run(until: 120)
        #expect(await world.holdsAfterALook(), "followed: kept however long")

        world.queue.sync { _ = world.hub.handle(NodeWire.Request(id: "9", kind: "unsubscribe", args: ["sub": .string("c1")]), on: client, rights: .read) }
        time.run(until: 120 + ChatStore.idleDrop - 5)
        #expect(await world.holdsAfterALook(), "nobody follows it, for less than a minute")
        time.run(until: 120 + ChatStore.idleDrop + Double(ChatStore.lookEvery) + 0.5)
        #expect(await eventually { !world.queue.sync { world.chats.holds(world.session) } }, "dropped a minute after its last follower")

        // Opened again, it starts past the old stream's seq: a client's old seq is never another stream's.
        let again = Recorder()
        try await world.subscribe(again, sub: "c1", extra: ["since": .object(["epoch": .string(world.hub.epoch), "seq": .int(seq)]),
                                                           "after": .string("u1")])
        #expect(again.messages.first?["result"]?["mode"] == .string("tail"))
        #expect((again.events[0]["seq"]?.int ?? 0) > seq)
        withExtendedLifetime(clock) {}
    }

    @Test func aSessionWithNoTranscriptIsGone() async throws {
        let world = try ChatWorld()
        var bare = LiveWorld.session("pts/8")
        bare.transcriptPath = nil
        world.sessions.send("local:pts/8", bare)
        let client = Recorder()
        for key in ["local:pts/8", "local:pts/404"] {
            world.queue.sync { _ = world.hub.handle(ChatWorld.subscribeRequest(sub: "c1", key: key), on: client, rights: .read) }
        }
        let replies = client.messages
        #expect(replies.count == 2 && replies.allSatisfy { $0["error"]?["code"] == .string("gone") }, "\(replies)")
        #expect(client.events.isEmpty)
        // Without a key it is out of form.
        world.queue.sync {
            _ = world.hub.handle(NodeWire.Request(id: "3", kind: "subscribe", args: ["sub": .string("c2"), "collection": .string("chat")]),
                                 on: client, rights: .read)
        }
        #expect(client.messages.last?["error"]?["code"] == .string("bad-args"))
    }

    @Test func aTranscriptOutsideTheAgentsFoldersIsRefused() async throws {
        let world = try ChatWorld()
        // A JSONL file in the home but outside the agents' folders, and a link inside them that leads out.
        let outside = world.home.appendingPathComponent("notes/secret.jsonl")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(ChatWorld.prompt("u1", "not a transcript").utf8).write(to: outside)
        let link = world.transcript.deletingLastPathComponent().appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let client = Recorder()
        for (tty, path) in [("pts/5", outside.path), ("pts/6", link.path)] {
            var session = LiveWorld.session(tty)
            session.transcriptPath = path
            world.sessions.send("local:\(tty)", session)
            world.queue.sync { _ = world.hub.handle(ChatWorld.subscribeRequest(sub: "c-\(tty.dropFirst(4))", key: "local:\(tty)"), on: client, rights: .read) }
        }
        let replies = client.messages
        #expect(replies.count == 2 && replies.allSatisfy { $0["error"]?["code"] == .string("gone") }, "\(replies)")
        #expect(client.events.isEmpty)
    }

    /// LW-D11: an image is its type and its size, never its bytes, in a prompt and in a tool's result.
    @Test func anImageCarriesNoBytes() async throws {
        let world = try ChatWorld()
        let bytes = Data((0..<3000).map { UInt8($0 % 251) })
        try world.append(ChatWorld.promptWithImage("u1", "What is this?", bytes))
        try world.append(ChatWorld.toolUse("a1", id: "t1", command: "screenshot"))
        try world.append(ChatWorld.toolResultWithImage("u2", id: "t1", bytes))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        let items = try #require(client.events[0]["items"]?.array)
        let promptImages = try #require(items.first?["images"]?.array)
        let resultImages = try #require(items.last?["tools"]?.array?.first?["result"]?["images"]?.array)
        for image in promptImages + resultImages {
            let id = image["id"] ?? .null
            #expect(image == NodeWire.Value.object(["id": id, "mediaType": .string("image/png"), "bytes": .int(bytes.count)]))
        }
        #expect(promptImages.count == 1 && resultImages.count == 1)
        let wire = String(decoding: NodeWire.message(client.events[0]), as: UTF8.self)
        #expect(!wire.contains(String(bytes.base64EncodedString().prefix(40))), "no byte of the image on the wire")
    }

    /// The file's own watch carries a write to the subscriber: no clock exists in this world.
    @Test func aWriteReachesTheSubscriberWithNoClock() async throws {
        let world = try ChatWorld()
        try world.append(ChatWorld.prompt("u1", "Go"))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        for index in 1...5 {
            try world.append(ChatWorld.reply("a\(index)", "Step \(index)"))
            try await client.waitFor(events: 1 + index)
        }
        // The client's list, applied op by op, is the stream's.
        var items = client.events[0]["items"]?.array ?? []
        for delta in client.events.dropFirst() { ChatWorld.apply(delta, to: &items) }
        #expect(items == world.queue.sync { world.stream?.items.map(\.value) })
    }

    /// Every item kind the reader makes, as the wire's schema has it: checked strictly (no key it lacks).
    @Test func everyItemIsWhatTheSchemaSays() async throws {
        for (index, item) in Samples.chatItems.enumerated() {
            let value = try #require(ChatValue.value(item), "item \(index)")
            #expect(WireSchema.check(value, as: "chat.item", strict: true) == nil, "item \(index): \(WireSchema.check(value, as: "chat.item", strict: true) ?? "")")
        }
        #expect(ChatValue.value(.newMarker(summary: "3 new")) == nil, "view state is the client's")
    }
}

/// A scratch home with one Claude session's transcript, a sessions store that names it, a chat store and a hub on one
/// engine queue.
final class ChatWorld: @unchecked Sendable {
    let queue: DispatchQueue
    let scratch: Scratch
    let home: URL
    let transcript: URL
    let session = "local:pts/3"
    let sessions = Changes<Session>()
    let hub: LiveHub
    let chats: ChatStore

    init(now: (@Sendable () -> TimeInterval)? = nil,
         window: (items: Int, bytes: Int) = (TranscriptFollow.windowItems, TranscriptFollow.windowBytes)) throws {
        scratch = Scratch()
        home = scratch.url("chat-home")
        transcript = home.appendingPathComponent(".claude/projects/-work-p/0f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: transcript)
        queue = DispatchQueue(label: "chat-engine")
        hub = LiveHub(queue: queue, epoch: UUID().uuidString, now: { LiveWorld.fixed })
        chats = ChatStore(queue: queue, home: home.path, sessions: sessions, now: now ?? { Date().timeIntervalSince1970 },
                          date: { LiveWorld.fixed }, window: window)
        hub.chats = chats
        var made = LiveWorld.session("pts/3")
        made.transcriptPath = transcript.path
        sessions.send(session, made)
    }

    /// A server restarted over the same home and transcript: a new queue, hub (a new epoch) and store.
    init(after: ChatWorld) throws {
        scratch = after.scratch
        home = after.home
        transcript = after.transcript
        queue = DispatchQueue(label: "chat-engine-2")
        hub = LiveHub(queue: queue, epoch: UUID().uuidString, now: { LiveWorld.fixed })
        chats = ChatStore(queue: queue, home: home.path, sessions: sessions, date: { LiveWorld.fixed })
        hub.chats = chats
        var made = LiveWorld.session("pts/3")
        made.transcriptPath = transcript.path
        sessions.send(session, made)
    }

    var stream: ChatStream? {
        guard case .opened(let stream) = chats.open(session) else { return nil }
        return stream
    }

    /// Lines appended to the transcript, each ending in a newline.
    func append(_ lines: String...) throws { try append(lines) }

    func append(_ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    /// The transcript replaced by a new file with `lines` (renamed into place: another inode, read from its start).
    func replace(with lines: [String]) throws {
        let next = transcript.deletingLastPathComponent().appendingPathComponent(".next")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: next)
        _ = try FileManager.default.replaceItemAt(transcript, withItemAt: next)
    }

    static func subscribeRequest(id: String = "1", sub: String, key: String, extra: [String: NodeWire.Value] = [:]) -> NodeWire.Request {
        NodeWire.Request(id: id, kind: "subscribe",
                         args: ["sub": .string(sub), "collection": .string("chat"), "key": .string(key)].merging(extra) { $1 })
    }

    /// Subscribes `client` to the session's chat and waits for the reply and, unless it is a resume, the first event.
    func subscribe(_ client: Recorder, sub: String, extra: [String: NodeWire.Value] = [:]) async throws {
        let before = client.messages.count
        queue.sync { _ = hub.handle(Self.subscribeRequest(sub: sub, key: session, extra: extra), on: client, rights: .read) }
        try #require(await eventually { client.messages.count > before }, "no reply to the chat's subscribe")
        let reply = client.messages[before]
        try #require(reply["ok"] == .bool(true), "\(reply)")
        if reply["result"]?["mode"] != .string("resume") {
            try #require(await eventually { client.messages.count > before + 1 }, "no first event after the reply")
        }
    }

    /// A request on the hub, and its reply.
    func request(_ client: Recorder, _ kind: String, _ args: [String: NodeWire.Value]) async throws -> NodeWire.Value {
        let id = UUID().uuidString
        queue.sync { _ = hub.handle(NodeWire.Request(id: id, kind: kind, args: args), on: client, rights: .read) }
        var found: NodeWire.Value?
        try #require(await eventually {
            found = client.messages.first { $0["re"] == .string(id) }
            return found != nil
        }, "no reply to \(kind)")
        return found ?? .null
    }

    /// Waits until the stream holds `count` items.
    func waitForItems(_ count: Int) async throws {
        try #require(await eventually { self.queue.sync { self.chats.holds(self.session) && (self.stream?.items.count ?? 0) >= count } },
                     "the stream never held \(count) items")
    }

    /// Whether the store still holds the chat after a look of its own (the sweep included).
    func holdsAfterALook() async -> Bool {
        queue.sync { chats.sweep() }
        return queue.sync { chats.holds(session) }
    }

    /// A client's items with a delta's ops applied, as the contract's client applies them.
    static func apply(_ delta: NodeWire.Value, to items: inout [NodeWire.Value]) {
        for op in delta["ops"]?.array ?? [] {
            switch op["op"]?.string {
            case "add": if let item = op["item"] { items.append(item) }
            case "set": if let item = op["item"], let index = items.firstIndex(where: { $0["id"] == item["id"] }) { items[index] = item }
            case "remove": items.removeAll { $0["id"] == op["id"] }
            case "text":
                guard let index = items.firstIndex(where: { $0["id"] == op["id"] }), case .object(var fields) = items[index],
                      let text = fields["text"]?.string, let append = op["append"]?.string else { continue }
                fields["text"] = .string(text + append)
                items[index] = .object(fields)
            default: break
            }
        }
    }

    // MARK: Transcript lines (Claude Code's)

    static let stamp = "2026-11-17T09:10:00.000Z"

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func prompt(_ uuid: String, _ text: String) -> String {
        line(["type": "user", "uuid": uuid, "timestamp": stamp, "message": ["role": "user", "content": text]])
    }

    static func reply(_ uuid: String, _ text: String) -> String {
        line(["type": "assistant", "uuid": uuid, "timestamp": stamp,
              "message": ["id": "msg-\(uuid)", "role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    static func toolUse(_ uuid: String, id: String, command: String) -> String {
        line(["type": "assistant", "uuid": uuid, "timestamp": stamp,
              "message": ["id": "msg-\(uuid)", "role": "assistant",
                          "content": [["type": "tool_use", "id": id, "name": "Bash", "input": ["command": command]]]]])
    }

    static func toolResult(_ uuid: String, id: String, output: String) -> String {
        line(["type": "user", "uuid": uuid, "timestamp": stamp,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": output]]]])
    }

    static func image(_ bytes: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": bytes.base64EncodedString()]]
    }

    static func promptWithImage(_ uuid: String, _ text: String, _ bytes: Data) -> String {
        line(["type": "user", "uuid": uuid, "timestamp": stamp,
              "message": ["role": "user", "content": [["type": "text", "text": text], image(bytes)]]])
    }

    static func toolResultWithImage(_ uuid: String, id: String, _ bytes: Data) -> String {
        line(["type": "user", "uuid": uuid, "timestamp": stamp,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id,
                                                       "content": [["type": "text", "text": "a screenshot"], image(bytes)]]]]])
    }

    // MARK: Values

    static func replyValue(_ id: String, _ text: String) -> NodeWire.Value {
        .object(["id": .string(id), "type": .string("reply"), "at": .null, "text": .string(text)])
    }

    static func value(prompt text: String, steered: Bool) -> NodeWire.Value {
        .object(["id": .string("p"), "type": .string("prompt"), "at": .null, "text": .string(text), "steered": .bool(steered),
                 "fromLead": .bool(false), "images": .array([])])
    }
}
