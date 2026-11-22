import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A chat held as a tail window (the architecture review's row 13, `TranscriptFollow`): the newest items in memory,
/// bounded in count and bytes; an append changes the stream at its tail only, and items that leave the window's front
/// leave silently; older items come from the file when a page asks for them, the same items a whole read makes, back to
/// the transcript's first, and an image in them is served; a page before an item that left the window finds it.
struct ChatWindowTests {
    /// `count` turns: a prompt, a tool call with its result, and a reply each.
    static func turns(_ range: Range<Int>) -> [String] {
        range.flatMap { index in
            [ChatWorld.prompt("u\(index)", "Step \(index)"), ChatWorld.toolUse("t\(index)", id: "tool\(index)", command: "ls \(index)"),
             ChatWorld.toolResult("r\(index)", id: "tool\(index)", output: "out \(index)"), ChatWorld.reply("a\(index)", "Did \(index)")]
        }
    }

    /// The items a whole read of the transcript makes (what the store showed before the window), as wire values.
    static func whole(_ url: URL) throws -> [NodeWire.Value] {
        var log = ChatLog()
        log.append(ChatReader.read(try Data(contentsOf: url), format: .claude).events)
        return ChatTimeline.items(log.entries, newAfter: nil).compactMap(ChatValue.value)
    }

    @Test func theWindowIsBoundedAndASnapshotSaysMoreAreOlder() async throws {
        let world = try ChatWorld(window: (items: 40, bytes: 1 << 20))
        try world.append(Self.turns(0..<50))
        let stream = try #require(world.queue.sync { world.stream })
        try #require(await eventually { world.queue.sync { stream.loaded } })
        let (count, older, snapshot) = world.queue.sync { (stream.items.count, stream.older, stream.snapshot(limit: 500)) }
        #expect(count <= 50 && count >= 20, "\(count) items held")
        #expect(older && snapshot.more, "the file holds items before the window")
        // The window is the whole read's tail, item for item.
        let whole = try Self.whole(world.transcript)
        #expect(Array(whole.suffix(count)) == world.queue.sync { stream.items.map(\.value) })
    }

    /// Appends past the window's bound: each a delta at the tail (no `remove` for items that left the front), and a
    /// client applying the deltas holds, at its end, exactly the window.
    @Test func anAppendIsATailDeltaAndTheFrontLeavesSilently() async throws {
        let world = try ChatWorld(window: (items: 40, bytes: 1 << 20))
        try world.append(Self.turns(0..<10))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        for index in 10..<60 {
            let seen = client.events.count
            try world.append(Self.turns(index..<(index + 1)))
            try #require(await eventually { client.events.count > seen && (client.events.last?["ops"]?.array?.contains { $0["item"]?["id"] == .string("a\(index).0") } ?? false) },
                         "turn \(index) never came")
        }
        let ops = client.events.dropFirst().flatMap { $0["ops"]?.array ?? [] }
        #expect(!ops.contains { $0["op"] == .string("remove") }, "nothing was removed: items left the front silently")
        var items = client.events[0]["items"]?.array ?? []
        for delta in client.events.dropFirst() { ChatWorld.apply(delta, to: &items) }
        let held = world.queue.sync { world.stream?.items.map(\.value) ?? [] }
        #expect(held.count < items.count && Array(items.suffix(held.count)) == held)
        #expect(items == (try Self.whole(world.transcript)), "the client holds every item, as a whole read makes them")
    }

    /// `chat.page` before the window's first item reads from the file: page after page, the same items a whole read
    /// makes, back to the first, the last page saying no more.
    @Test func olderPagesComeFromTheFileBackToTheFirstItem() async throws {
        let world = try ChatWorld(window: (items: 40, bytes: 1 << 20))
        try world.append(Self.turns(0..<120))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1", extra: ["limit": .int(30)])
        var held = client.events[0]["items"]?.array ?? []
        var more = client.events[0]["more"]?.bool ?? false
        var pages = 0
        while more, let first = held.first?["id"]?.string {
            let page = try await world.request(client, "chat.page", ["session": .string(world.session), "before": .string(first), "limit": .int(50)])
            let items = try #require(page["result"]?["items"]?.array, "\(page)")
            #expect(WireSchema.check(page, as: "reply.chat.page") == nil)
            held = items + held
            more = page["result"]?["more"]?.bool ?? false
            pages += 1
            try #require(pages < 40, "paging never ended")
        }
        #expect(held == (try Self.whole(world.transcript)), "every item, in order, as a whole read makes them")
        #expect(pages > 3)
    }

    /// An image in an item that only the file holds now (a page brought it) is served by `chat.image`, as one in the
    /// window is.
    @Test func anImageInAnOlderPageIsServed() async throws {
        let world = try ChatWorld(window: (items: 30, bytes: 1 << 20))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 300)
        try world.append([ChatWorld.toolUse("s0", id: "shot", command: "screenshot"), ChatWorld.toolResultWithImage("s1", id: "shot", png)]
                         + Self.turns(0..<60))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        var held = client.events[0]["items"]?.array ?? []
        while let first = held.first?["id"]?.string, held.first?["id"] != .string("tools:shot") {
            let page = try await world.request(client, "chat.page", ["session": .string(world.session), "before": .string(first), "limit": .int(100)])
            held = (page["result"]?["items"]?.array ?? []) + held
            if page["result"]?["more"]?.bool != true { break }
        }
        let shot = try #require(held.first { $0["id"] == .string("tools:shot") }, "the screenshot's item never came")
        let imageID = try #require(shot["tools"]?.array?.first?["result"]?["images"]?.array?.first?["id"]?.string, "\(shot)")
        let image = try await world.request(client, "chat.image", ["session": .string(world.session), "id": .string(imageID)])
        #expect(image["result"]?["data"]?.string == png.base64EncodedString(), "\(image)")
    }

    /// A page before an item a client holds that has since left the window (the window moved on): found by its bookmark.
    @Test func aPageBeforeAnItemThatLeftTheWindowFindsIt() async throws {
        let world = try ChatWorld(window: (items: 40, bytes: 1 << 20))
        try world.append(Self.turns(0..<30))
        let client = Recorder()
        try await world.subscribe(client, sub: "c1")
        let first = try #require(client.events[0]["items"]?.array?.first?["id"]?.string)
        try world.append(Self.turns(30..<80))
        try #require(await eventually { world.queue.sync { world.stream?.position(of: first) == nil } }, "the item never left the window")
        let page = try await world.request(client, "chat.page", ["session": .string(world.session), "before": .string(first), "limit": .int(10)])
        let items = try #require(page["result"]?["items"]?.array, "\(page)")
        let whole = try Self.whole(world.transcript)
        let at = try #require(whole.firstIndex { $0["id"] == .string(first) })
        #expect(items == Array(whole[max(0, at - 10)..<at]))
    }

    /// The bytes bound: screenshot-sized lines keep the window to its bytes (never under `minItems` items).
    @Test func screenshotLinesKeepTheWindowToItsBytes() throws {
        let scratch = Scratch()
        let url = scratch.url("t.jsonl")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 9, count: 200 * 1024)
        var lines: [String] = []
        for index in 0..<80 {
            lines += [ChatWorld.prompt("u\(index)", "Shot \(index)"), ChatWorld.toolUse("t\(index)", id: "s\(index)", command: "shot"),
                      ChatWorld.toolResultWithImage("r\(index)", id: "s\(index)", png)]
        }
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        let follow = TranscriptFollow(url: url, format: .claude, windowItems: 600, windowBytes: 4 << 20)
        let change = try #require(follow.read())
        #expect(change.reset && change.older)
        // About 270 KB a shot (base64): some 15 shots' items fit in 4 MB, never the whole 80.
        #expect(follow.window.count < 60 && follow.window.count >= TranscriptFollow.minItems, "\(follow.window.count)")
    }
}
