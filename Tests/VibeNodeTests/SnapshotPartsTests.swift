import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Snapshots in parts (the architecture review's row 14, bounded by construction): a client that asks (`subscribe`'s
/// `parts`) gets a snapshot as messages of at most `NodeWire.partBytes` each, `part` 0, 1, ... and `final` on the last,
/// whatever the collection holds; an entry past a part's room is withheld whole and named (a card with a stub in its
/// place: what a person decides on is never cut), or, in the boards alone, has its longest texts cut; the rest is sent
/// whole; a delta larger than a part is a snapshot in parts instead. A client that doesn't ask gets one
/// message as before (fitted to a line), and a delta past a line is a fitted snapshot for it, never a message the
/// socket would refuse.
@Suite(.timeLimit(.minutes(5)))
struct SnapshotPartsTests {
    private let scratch = Scratch()

    // MARK: Parts

    /// What a client holds after a snapshot's parts: their entries in order and the ids withheld, each part checked
    /// (its place, its envelope, its size, the schema). Nil when they don't make one snapshot.
    static func assembled(_ parts: [Data], epoch: String = "e", seq: Int = 1) -> (entries: [NodeWire.Entry], withheld: [NodeWire.Withheld])? {
        var entries: [NodeWire.Entry] = [], withheld: [NodeWire.Withheld] = []
        for (index, data) in parts.enumerated() {
            #expect(data.count <= NodeWire.partBytes, "part \(index): \(data.count) bytes")
            guard let part = NodeWire.decode(NodeWire.Snapshot.self, data), part.part == index, part.final == (index == parts.count - 1),
                  part.epoch == epoch, part.seq == seq, part.truncated == nil else { return nil }
            // Its envelope (these cases' entries are made-up values, not the collection's).
            var envelope = part
            envelope.entries = []
            #expect(WireSchema.check(NodeWire.decode(NodeWire.Value.self, NodeWire.message(envelope)) ?? .null, as: "snapshot", strict: true) == nil)
            entries += part.entries
            withheld += part.withheld ?? []
        }
        return (entries, withheld)
    }

    /// The 1.4 MB cards incident's case and three leads' boards: in parts, each under the bound, every entry sent, in
    /// order, nothing truncated.
    @Test func aSnapshotPastALineIsSentWholeInPartsEachUnderTheBound() throws {
        let at = Date(timeIntervalSince1970: 1_000_000)
        var entries: [NodeWire.Entry] = []
        var closedBytes = 0
        while closedBytes < CardStore.keptClosedBytes {
            let card = SnapshotSizeTests.card(bytes: 4_000, closed: true, at: at)
            closedBytes += NodeWire.message(card.value).count
            entries.append(.init(id: card.id, value: card.value))
        }
        entries += (0..<8).map { _ in SnapshotSizeTests.card(bytes: 100_000, closed: false, at: at) }.map { .init(id: $0.id, value: $0.value) }
        let cards = NodeWire.Snapshot(sub: "s3", collection: "cards", epoch: "e", seq: 1, entries: entries)
        #expect(NodeWire.message(cards).count > NodeWire.maxLine, "the case passes a line whole")
        let parts = LiveHub.parted(cards)
        #expect(parts.count >= 5, "\(parts.count)")
        let read = try #require(Self.assembled(parts))
        #expect(read.entries == entries && read.withheld.isEmpty)

        let board = { (size: Int) -> NodeWire.Value in .object(["tasks": .array((0..<(size / 1_000)).map { _ in .string(String(repeating: "t", count: 990)) })]) }
        let boards = NodeWire.Snapshot(sub: "s4", collection: "boards", epoch: "e", seq: 1,
                                       entries: ["a", "b", "c", "d", "e"].map { NodeWire.Entry(id: $0, value: board(240_000)) })
        let boardParts = LiveHub.parted(boards)
        #expect(try #require(Self.assembled(boardParts)).entries == boards.entries)
        #expect(boardParts.count == 5, "one board a part: \(boardParts.count)")
    }

    @Test func aSnapshotThatFitsIsOnePart() throws {
        let small = NodeWire.Snapshot(sub: "s", collection: "sessions", epoch: "e", seq: 1, entries: [.init(id: "a", value: .int(1))])
        let parts = LiveHub.parted(small)
        try #require(parts.count == 1)
        let part = try #require(NodeWire.decode(NodeWire.Snapshot.self, parts[0]))
        #expect(part.part == 0 && part.final == true && part.entries == small.entries && part.withheld == nil)
        let empty = LiveHub.parted(NodeWire.Snapshot(sub: "s", collection: "cards", epoch: "e", seq: 1, entries: []))
        #expect(try #require(Self.assembled(empty)).entries.isEmpty)
    }

    /// A plugin card (the shell plugin's) whose body is `bytes` long: past the plugin's own bound (`bodyBytesAtMost`,
    /// which refuses one that long before it is ever a card), so made here by hand.
    static func shellCard(bodyBytes: Int, at: Date) -> CardStore.Card {
        var card = CardStore.Card(root: "/scratch/repo", kind: .plugin, at: at)
        let run = PluginCard.Action(word: "run", label: "Run", acts: true, short: "runs it", does: "runs it", verb: "run it", marks: "starting")
        let line = String(repeating: "y", count: 99)
        let body = (0..<(bodyBytes / 100)).map { "echo \($0) \(line)" }.joined(separator: "\n")
        card.plugin = PluginCard(plugin: "shell", request: UUID().uuidString, session: "local:0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10",
                                 asker: "Claude · repo", title: "A shell asked for", noun: "shell request", ask: "asks for a shell",
                                 facts: [.init(name: "folder", label: "in the folder", value: "/scratch/repo", folder: true, decisive: true)],
                                 body: .init(name: "command", label: "running exactly this", text: body), expiresAt: at, actions: [run])
        return card
    }

    /// Text a person decides on is never cut: a shell card whose body is 300 KiB and a question of a megabyte are each
    /// withheld whole, named with their bytes and a stub in their place (where they belong, the command that shows them,
    /// nothing of what they ask); every other card is sent as it is; the command line still shows the body whole.
    @Test func aCardPastAPartIsWithheldWholeNeverCut() throws {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let shell = Self.shellCard(bodyBytes: 300 * 1024, at: at)
        let question = SnapshotSizeTests.card(bytes: 1_000_000, closed: false, at: at)
        let small = SnapshotSizeTests.card(bytes: 100, closed: false, at: at)
        let snapshot = NodeWire.Snapshot(sub: "s3", collection: "cards", epoch: "e", seq: 1,
                                         entries: [shell, question, small].map { .init(id: $0.id, value: $0.value) })
        let parts = LiveHub.parted(snapshot, oversized: .withhold(stub: CardStore.Card.tooLargeStub))
        let read = try #require(Self.assembled(parts))
        #expect(read.entries == [.init(id: small.id, value: small.value)], "only the card that fits, as it is")
        #expect(read.withheld.map(\.id) == [shell.id, question.id])
        // Nothing cut anywhere: no part holds a cut mark, nor any of the body's or the question's text.
        for data in parts {
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("[cut: ") && !text.contains("echo 7 ") && !text.contains(String(repeating: "x", count: 200)), "the small card's question is 100 bytes")
        }
        let stub = try #require(read.withheld.first?.stub)
        #expect(stub["id"] == .string(shell.id) && stub["kind"] == .string("plugin") && stub["open"] == .bool(true))
        #expect(stub["plugin"]?["session"] == shell.value["plugin"]?["session"] && stub["plugin"]?["body"] == nil)
        #expect(stub["tooLarge"]?["command"] == .string("vibeswitcher questions"))
        #expect(stub["tooLarge"]?["bytes"] == .int(read.withheld[0].bytes) && read.withheld[0].bytes > NodeWire.partBytes)
        #expect(read.withheld[1].stub?["question"] == nil, "a question's stub holds nothing it asks")
        // The command line's card (`vibeswitcher questions`, CardText): every line of the body, whole.
        let lines = CardText.lines(shell.value)
        #expect(lines.contains("    | echo 0 \(String(repeating: "y", count: 99))") && lines.contains("    | echo \(300 * 1024 / 100 - 1) \(String(repeating: "y", count: 99))"),
                "\(lines.prefix(12))")
        // The plugin's own bound keeps a real card's body far under a part.
        #expect(PluginCard.bodyBytesAtMost * 2 < NodeWire.entryBytes)
    }

    /// Withheld by default: a collection that doesn't say it may cut sends an oversized entry nowhere, cut nowhere.
    @Test func anOversizedEntryIsWithheldUnlessItsCollectionMayCut() throws {
        let long = NodeWire.Entry(id: "long", value: .object(["prompt": .string(String(repeating: "p", count: 400_000))]))
        let snapshot = NodeWire.Snapshot(sub: "s1", collection: "sessions", epoch: "e", seq: 1, entries: [long, .init(id: "a", value: .int(1))])
        let read = try #require(Self.assembled(LiveHub.parted(snapshot)))
        #expect(read.entries.map(\.id) == ["a"] && read.withheld == [NodeWire.Withheld(id: "long", bytes: NodeWire.message(long).count + 1)])
    }

    /// The boards, which hold nothing a person decides on: a note of a megabyte is cut, its start kept and the cut
    /// marked; an entry whose shape alone passes a part (a hundred thousand small values) is withheld and named.
    @Test func aBoardPastAPartHasItsLongestTextCut() throws {
        let note = NodeWire.Entry(id: "note", value: .object(["tasks": .array([.object(["blocker": .string(String(repeating: "x", count: 1_000_000)),
                                                                                        "slug": .string("t")])])]))
        let shape = NodeWire.Entry(id: "many", value: .array((0..<100_000).map { .int($0) }))
        let small = NodeWire.Entry(id: "small", value: .object(["tasks": .array([])]))
        let snapshot = NodeWire.Snapshot(sub: "s4", collection: "boards", epoch: "e", seq: 1, entries: [note, shape, small])
        let read = try #require(Self.assembled(LiveHub.parted(snapshot, oversized: .cut)))
        #expect(read.entries.map(\.id) == ["note", "small"], "\(read.entries.map(\.id))")
        #expect(read.withheld.map(\.id) == ["many"] && read.withheld[0].stub == nil)
        #expect(read.entries[1] == small, "an entry that fits is sent as it is")
        let text = try #require(read.entries[0].value["tasks"]?.array?.first?["blocker"]?.string)
        #expect(text.hasPrefix(String(repeating: "x", count: 100_000)) && text.hasSuffix(" bytes]") && text.contains("… [cut: "), "\(text.suffix(40))")
        #expect(read.entries[0].value["tasks"]?.array?.first?["slug"] == .string("t"), "short fields are never cut")
    }

    /// A board's own rule keeps its value under a part's room, with space for its id: a board is never withheld.
    @Test func aBoardsBudgetFitsAPart() {
        #expect(BoardValue.mostBytes + 4_096 <= NodeWire.entryBytes)
        #expect(NodeWire.entryBytes < NodeWire.partBytes && NodeWire.partBytes < NodeWire.maxLine)
    }

    // MARK: The hub

    /// On the hub: a subscriber that asks gets parts, and a change larger than a part is a snapshot in parts (a delta of
    /// it would pass the bound); one that doesn't ask gets one fitted message, and a change past a line a fitted snapshot.
    @Test func theHubSendsPartsToWhoAsksAndNoDeltaPastItsBound() async throws {
        let world = LiveWorld()
        let big = { (round: Int) -> NodeWire.Value in .string(String(repeating: "\(round % 10)", count: 200_000)) }
        for index in 0..<6 { world.store.send("e\(index)", big(0)) }
        try await world.settled(6)
        let parts = Recorder(), whole = Recorder()
        world.queue.sync {
            _ = world.hub.handle(NodeWire.Request(id: "1", kind: "subscribe", args: ["sub": .string("p"), "collection": .string("things"),
                                                                                  "parts": .bool(true)]), on: parts, rights: .read)
        }
        world.subscribe(whole, sub: "w")
        let first = parts.events
        #expect(first.count == 6 && first.allSatisfy { $0["part"]?.int != nil }, "\(first.count) events")
        #expect(first.last?["final"] == .bool(true) && first.flatMap { $0["entries"]?.array ?? [] }.count == 6)
        let fitted = try #require(whole.events.first)
        #expect(whole.events.count == 1 && fitted["truncated"] == .bool(true) && fitted["part"] == nil)

        // Every entry changes while neither can write: on the drain, a delta would be 1.2 MB.
        parts.writable = false
        whole.writable = false
        for index in 0..<6 { world.store.send("e\(index)", big(1)) }
        let seq = try await world.mark()
        world.queue.sync {}
        parts.drain()
        whole.drain()
        try #require(await eventually { parts.events.last?["seq"] == .int(seq) && whole.events.last?["seq"] == .int(seq) })
        let again = Array(parts.events.dropFirst(first.count))
        #expect(again.allSatisfy { $0["kind"] == .string("snapshot") && $0["part"]?.int != nil }, "no delta past a part")
        let rows = again.flatMap { $0["entries"]?.array ?? [] }
        #expect(rows.count == 7 && rows.filter { $0["value"] == big(1) }.count == 6, "every entry as it is now, the marker too")
        let late = Array(whole.events.dropFirst())
        #expect(late.count == 1 && late[0]["kind"] == .string("snapshot") && late[0]["truncated"] == .bool(true), "a fitted snapshot, not a 1.2 MB delta")
        let sizes = (parts.messages + whole.messages).map { NodeWire.message($0).count }
        #expect(sizes.allSatisfy { $0 <= NodeWire.maxLine }, "\(sizes.max() ?? 0)")
        #expect(parts.closes.isEmpty && whole.closes.isEmpty)
    }

    // MARK: A node

    /// The boards of six leads, each at its budget (150 tasks near their caps), a lead's question card the shell plugin
    /// drew, and the leads: the boards pass a line whole (1.4 MB). A client on the Unix socket and a page on the
    /// WebSocket each ask for parts and hold the whole state, the same, every message under the bound; a client that
    /// doesn't ask gets one fitted message and stays connected.
    @Test(NodeTraits.linuxOnly) func everyClientHoldsTheWholeStateOfANodePastALine() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        var roots: [URL] = []
        for index in 0..<6 {
            let root = node.root.appendingPathComponent("big-\(index)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try BoardStore(root: root.path).update { board in
                board.tasks = (0..<150).map { task in
                    var made = LeadTask(id: "t\(task)", slug: "task-\(task)", title: "\(index)-\(task) " + String(repeating: "界", count: 1_000),
                                        contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""), status: .blocked)
                    made.blocker = String(repeating: "原因 ", count: 3_000)
                    return made
                }
            }
            // A lead session for it, as the host lists one: the node's lead store takes its root, and reads its board.
            _ = try await node.spawn("exec sleep 600", cwd: root.path, label: "Lead · big-\(index)")
            roots.append(root)
        }
        _ = try await PageCheckTests.askShell(node, command: "echo parts")
        let projects = Set(roots.map { NodeIds.project(root: $0.path) })
        let complete: ([String: NodeWire.Value]) -> Bool = { boards in
            Set(boards.keys) == projects && boards.values.allSatisfy { ($0["tasks"]?.array?.count ?? 0) > 0 }
        }

        // The Unix socket: subscribed with parts, followed until every board is in.
        let unix = try WireClient(node)
        var socketFeed = Feed()
        for (sub, collection) in [("b", "boards"), ("c", "cards"), ("l", "leads")] {
            let answered = unix.request("subscribe", args: ["sub": .string(sub), "collection": .string(collection), "parts": .bool(true)], action: nil)
            for message in answered { socketFeed.take(message) }
        }
        let deadline = Date().addingTimeInterval(120)
        while !(complete(socketFeed.rows["b"] ?? [:]) && (socketFeed.rows["c"] ?? [:]).values.contains { $0["kind"] == .string("plugin") }),
              Date() < deadline {
            for message in unix.next(timeout: 1) { socketFeed.take(message) }
        }
        try #require(complete(socketFeed.rows["b"] ?? [:]), "boards: \((socketFeed.rows["b"] ?? [:]).keys.sorted()) of \(projects.sorted())\n\(node.said)")
        // The boards came as deltas, a board at a time, as each was read: a new subscription's snapshot is in parts.
        let snapshotted = unix.request("subscribe", args: ["sub": .string("b2"), "collection": .string("boards"), "parts": .bool(true)], action: nil)
        for message in snapshotted { socketFeed.take(message) }
        while socketFeed.seq["b2"] == nil, Date() < deadline {
            for message in unix.next(timeout: 1) { socketFeed.take(message) }
        }
        let boards = try #require(socketFeed.rows["b2"], "\(node.said)")
        #expect(boards == socketFeed.rows["b"] && socketFeed.seq["b2"] == socketFeed.seq["b"], "the snapshot holds what the deltas built")
        let whole = NodeWire.message(NodeWire.Snapshot(sub: "b", collection: "boards", epoch: "e", seq: 1,
                                                       entries: boards.map { NodeWire.Entry(id: $0.key, value: $0.value) }))
        #expect(whole.count > NodeWire.maxLine, "the boards pass a line whole: \(whole.count)")
        #expect(socketFeed.biggest <= NodeWire.partBytes && socketFeed.parted, "\(socketFeed.biggest)")
        #expect(socketFeed.withheld.isEmpty && socketFeed.problems.isEmpty, "\(socketFeed.problems)")
        for (project, board) in boards {
            let tasks = try #require(board["tasks"]?.array)
            #expect(board["more"] == .int(150 - tasks.count) && tasks.first?["slug"] == .string("task-0"), "\(project)")
            #expect(NodeWire.message(board).count <= BoardValue.mostBytes)
        }
        #expect(Set((socketFeed.rows["l"] ?? [:]).keys).isSuperset(of: projects), "every lead listed")

        // The page's WebSocket: paired, subscribed with parts, the same state.
        let opened = try LiveScratch.open(node)
        let page = try LivePage(port: opened.port)
        page.client.mostFrame = NodeWire.partBytes
        _ = try page.send("auth", ["pair": .string(opened.code), "client": .string("test")])
        var pageFeed = Feed()
        for (sub, collection) in [("b", "boards"), ("c", "cards")] {
            _ = try page.send("subscribe", ["sub": .string(sub), "collection": .string(collection), "parts": .bool(true)])
        }
        while pageFeed.seq["b"] == nil || pageFeed.seq["c"] == nil {
            let frame = try #require(try page.client.nextFrame(), "the page's socket ended: \(pageFeed.problems)")
            pageFeed.take(frame.payload)
        }
        #expect(pageFeed.biggest <= NodeWire.partBytes && pageFeed.parted && pageFeed.problems.isEmpty, "\(pageFeed.problems)")
        // At the same seq, the same rows (the boards are still: their files don't change).
        #expect(pageFeed.seq["b"] == socketFeed.seq["b"], "\(String(describing: pageFeed.seq["b"])) \(String(describing: socketFeed.seq["b"]))")
        #expect(pageFeed.rows["b"] == boards && pageFeed.rows["c"] == socketFeed.rows["c"])

        // A client that doesn't ask for parts: one message under a line, truncated, and still connected.
        let old = try WireClient(node)
        let answered = old.request("subscribe", args: ["sub": .string("o"), "collection": .string("boards")], action: nil)
        let snapshot = try #require(answered.count == 1 ? old.next(until: { _ in true }).first : answered.last)
        let read = try #require(NodeWire.decode(NodeWire.Snapshot.self, snapshot))
        #expect(snapshot.count <= NodeWire.maxLine && read.truncated == true && read.part == nil && !read.entries.isEmpty)
        #expect(!old.closed(within: 1))
    }
}

/// A client's state from a feed of messages, as the page holds it: each subscription's rows and `seq`, a snapshot's
/// parts held until the last; what went wrong, the largest message, whether any came in parts.
struct Feed {
    var rows: [String: [String: NodeWire.Value]] = [:]
    var seq: [String: Int] = [:]
    var held: [String: (next: Int, seq: Int, entries: [NodeWire.Entry])] = [:]
    var withheld: [NodeWire.Withheld] = []
    var problems: [String] = []
    var biggest = 0
    var parted = false

    mutating func take(_ data: Data) {
        biggest = max(biggest, data.count)
        guard let message = NodeWire.decode(NodeWire.Value.self, data), let sub = message["sub"]?.string else { return }
        if message["kind"] == .string("snapshot"), let snapshot = NodeWire.decode(NodeWire.Snapshot.self, data) {
            guard let part = snapshot.part else {
                rows[sub] = Dictionary(snapshot.entries.map { ($0.id, $0.value) }) { $1 }
                seq[sub] = snapshot.seq
                return
            }
            parted = parted || snapshot.final != true || part > 0
            if part == 0 { held[sub] = (0, snapshot.seq, []) }
            guard var holding = held[sub], holding.next == part, holding.seq == snapshot.seq else {
                problems.append("\(sub): part \(part) out of its place")
                held[sub] = nil
                return
            }
            holding.entries += snapshot.entries
            holding.next += 1
            withheld += snapshot.withheld ?? []
            held[sub] = holding
            if snapshot.final == true {
                rows[sub] = Dictionary(holding.entries.map { ($0.id, $0.value) }) { $1 }
                seq[sub] = snapshot.seq
                held[sub] = nil
            }
        } else if message["kind"] == .string("delta"), let delta = NodeWire.decode(NodeWire.Delta.self, data) {
            guard delta.prev == seq[sub] else { return problems.append("\(sub): a delta from \(delta.prev) at \(String(describing: seq[sub]))") }
            for change in delta.changes { rows[sub, default: [:]][change.id] = change.value == .null ? nil : change.value }
            seq[sub] = delta.seq
        }
    }
}
