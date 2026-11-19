import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A session's terminal in a page (the live plan's B6 and I4, the live wire contract's §9), on a `ScratchNode` whose
/// server takes `--test-web-terminal`: `term.open`, the host's replay and then its live bytes as binary frames, the
/// page's input typed into the session (a scratch one's: AGENTS.md's first hard rule), a page that stops reading
/// resynced from the host's replay, the page's emulator's answers to queries dropped, and the user's server opening
/// none.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct TerminalRelayTests {
    private let scratch = Scratch()

    /// A scratch node's server that opens terminals to its pages.
    static let terminalArguments = LiveScratch.webArguments + ["--server-arg", ServerArguments.testWebTerminalFlag]

    /// The reply to `term.open` comes first, then the host's replay as type 1 (what the program printed before the page
    /// came), then type 2, and then what it prints next, live, as type 1: all on the stream the reply named.
    @Test func attachReplaysThenGoesLive() async throws {
        let node = try await ScratchNode(scratch, hostArguments: Self.terminalArguments)
        defer { node.stop() }
        let printed = node.root.appendingPathComponent("printed"), go = node.root.appendingPathComponent("go")
        let session = try await node.spawn("printf 'before-the-page\\n'; touch '\(printed.path)'; "
            + "while [ ! -e '\(go.path)' ]; do sleep 0.05; done; printf 'after-the-page\\n'; exec sleep 600")
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: printed.path) }, "\(node.said)")
        let page = try TermPage.paired(node)
        let hello = try #require(page.hello)
        let kinds = Set(hello["kinds"]?.array?.compactMap(\.string) ?? [])
        #expect(kinds.contains("term.open") && kinds.contains("term.close"), "\(hello)")

        let id = try page.send("term.open", ["session": .string(NodeIds.session(host: session.id)), "cols": .int(100), "rows": .int(30)])
        let reply = try #require(try page.next()?.json, "no reply to term.open: \(node.said)")
        #expect(reply["re"]?.string == id && reply["ok"]?.bool == true, "\(reply)")
        let stream = try #require(reply["result"]?["stream"]?.int.flatMap(UInt32.init(exactly:)), "\(reply)")
        let replay = try #require(try page.until { $0.term?.kind == 2 }, "no end of the replay: \(node.said)")
        let replayed = replay.compactMap(\.term)
        #expect(replayed.allSatisfy { $0.stream == stream }, "\(replayed)")
        #expect(replayed.dropLast().allSatisfy { $0.kind == 1 }, "\(replayed.map(\.kind))")
        let replayText = String(decoding: replayed.filter { $0.kind == 1 }.flatMap(\.payload), as: UTF8.self)
        #expect(replayText.contains("before-the-page") && !replayText.contains("after-the-page"), "\(replayText)")

        FileManager.default.createFile(atPath: go.path, contents: nil)
        var live = ""
        let went = try page.until { item in
            guard let term = item.term, term.stream == stream, term.kind == 1 else { return false }
            live += String(decoding: term.payload, as: UTF8.self)
            return live.contains("after-the-page")
        }
        #expect(went != nil, "the live bytes never came: \(live)\n\(node.said)")
        #expect(went?.allSatisfy { $0.term?.kind == 1 && $0.term?.stream == stream } == true, "\(String(describing: went))")
        #expect(page.unsound.isEmpty, "\(page.unsound)")
    }

    /// What the page types reaches the session's program (a fake Claude Code's prompt box on a scratch node), as typed.
    @Test func inputReachesTheProgram() async throws {
        let node = try await ScratchNode(scratch, hostArguments: Self.terminalArguments)
        defer { node.stop() }
        let (session, files) = try await Self.fakeClaude(node)
        let page = try TermPage.paired(node)
        let stream = try page.open(session)
        _ = try #require(try page.until { $0.term?.kind == 2 }, "no end of the replay: \(node.said)")

        try page.type("hello from the page", on: stream)
        try #require(await eventually(timeout: 60) { Self.state(files)["input"] as? String == "hello from the page" },
                     "the box holds \(String(describing: Self.state(files)["input"])): \(node.said)")
        try page.type("\r", on: stream)
        let prompt = try await EngineEndToEndTests.prompt(files, timeout: 60) { $0 == "hello from the page" }
        #expect(prompt == "hello from the page")
    }

    /// A page that stops reading falls behind: nothing more is written to it, and once it reads again it gets type 4,
    /// then the host's replay as type 1, then type 2, and the session goes on from there (here, the end of a flood the
    /// page wasn't reading).
    @Test func aSlowClientIsResynced() async throws {
        let node = try await ScratchNode(scratch, hostArguments: Self.terminalArguments)
        defer { node.stop() }
        let go = node.root.appendingPathComponent("go"), stop = node.root.appendingPathComponent("stop")
        let session = try await node.spawn("printf 'waiting\\n'; while [ ! -e '\(go.path)' ]; do sleep 0.05; done; "
            + "while [ ! -e '\(stop.path)' ]; do yes 0123456789abcdefghijklmnopqrstuvwxyz | head -c 262144; done; "
            + "printf '\\nthe-flood-is-over\\n'; exec sleep 600")
        let page = try TermPage.paired(node)
        let stream = try page.open(session)
        _ = try #require(try page.until { $0.term?.kind == 2 }, "no end of the replay: \(node.said)")

        // The page reads nothing from here until the server says it fell behind.
        FileManager.default.createFile(atPath: go.path, contents: nil)
        try #require(await eventually(timeout: 120) { node.said.contains("terminal stream \(stream) fell behind") }, "\(node.said)")
        FileManager.default.createFile(atPath: stop.path, contents: nil)

        let toResync = try #require(try page.until { $0.term?.kind == 4 }, "no resync: \(node.said)")
        #expect(toResync.compactMap(\.term).dropLast().allSatisfy { $0.kind == 1 }, "before the resync, only bytes")
        #expect(toResync.last?.term?.stream == stream)
        let again = try #require(try page.until { $0.term?.kind == 2 }, "no end of the second replay: \(node.said)")
        #expect(again.compactMap(\.term).dropLast().allSatisfy { $0.kind == 1 && $0.stream == stream },
                "the replay is bytes alone: \(again.compactMap(\.term).filter { $0.kind != 1 }) of \(again.count)\n\(Self.terminalLines(node))")
        var after = String(decoding: again.compactMap(\.term).filter { $0.kind == 1 }.flatMap(\.payload), as: UTF8.self)
        if !after.contains("the-flood-is-over") {
            let rest = try page.until { item in
                guard let term = item.term, term.kind == 1 else { return false }
                after += String(decoding: term.payload, as: UTF8.self)
                return after.contains("the-flood-is-over")
            }
            #expect(rest != nil, "the session's end of the flood never came after the resync")
        }
        #expect(page.unsound.isEmpty, "\(page.unsound)")
    }

    /// What the page's emulator answers to a program's queries (a cursor position, the device attributes, a colour, a
    /// focus report) never reaches the program; what was typed with it does, and the log says how much was dropped.
    @Test func aTerminalQuerysReplyFromTheClientIsDropped() async throws {
        let node = try await ScratchNode(scratch, hostArguments: Self.terminalArguments)
        defer { node.stop() }
        let (session, files) = try await Self.fakeClaude(node)
        let page = try TermPage.paired(node)
        let stream = try page.open(session)
        _ = try #require(try page.until { $0.term?.kind == 2 }, "no end of the replay: \(node.said)")

        let answers = "\u{1b}[12;40R\u{1b}[?62;22c\u{1b}]11;rgb:0000/0000/0000\u{1b}\\"
        try page.type(answers + "zebra-quartz" + "\u{1b}[>0;276;0c", on: stream)
        try page.type("\u{1b}[I\u{1b}[?1;2$y", on: stream)
        try #require(await eventually(timeout: 60) { Self.state(files)["input"] as? String == "zebra-quartz" },
                     "the box holds \(String(describing: Self.state(files)["input"])): \(node.said)")
        try page.type("\r", on: stream)
        let prompt = try await EngineEndToEndTests.prompt(files, timeout: 60) { !$0.isEmpty }
        #expect(prompt == "zebra-quartz")
        #expect(node.said.contains("terminal stream \(stream): \(Array(answers.utf8).count + 11) bytes of the page's answers to queries dropped"),
                "\(node.said)")
        #expect(!node.said.contains("zebra"), "terminal text in the log")
        #expect(Self.state(files)["focusIns"] as? Int ?? 0 == 0, "a focus report reached the program")

        // Keys go as they came: arrows, modified ones, F5, F3 in its SS3 form, a paste's markers, the mouse, Escape.
        let keys = "\u{1b}[A\u{1b}[1;5C\u{1b}[15~\u{1b}OR\u{1b}[200~pasted\u{1b}[201~\u{1b}[<0;10;5M\u{1b}[Z\u{1b}"
        #expect(TerminalReplies.strip(Array(keys.utf8)) == (Array(keys.utf8), 0))
        #expect(TerminalReplies.strip(Array("a\u{1b}[6;1Rb\u{1b}P>|xterm\u{1b}\\c\u{1b}[?1u\u{1b}[8;30;100t".utf8)).kept == Array("abc".utf8))
    }

    /// The user's server opens no terminal (LW-D12): a server without `--test-web-terminal` answers `term.open`
    /// `unknown-kind` and doesn't list it in `hello`, a binary frame does nothing, and the user's server (`--node`)
    /// refuses the flag.
    @Test func theUsersServerOpensNoTerminal() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let session = try await node.spawn("printf 'not for the page\\n'; exec sleep 600")
        let page = try TermPage.paired(node)
        let kinds = page.hello?["kinds"]?.array?.compactMap(\.string) ?? []
        #expect(!kinds.contains("term.open") && !kinds.contains("term.close") && kinds.contains("subscribe"), "\(kinds)")
        for kind in ["term.open", "term.close"] {
            let id = try page.send(kind, ["session": .string(NodeIds.session(host: session.id)), "cols": .int(80), "rows": .int(24), "stream": .int(1)])
            let reply = try #require(try page.next()?.json, "no reply to \(kind)")
            #expect(reply["re"]?.string == id && reply["error"]?["code"]?.string == NodeWire.Code.unknownKind.rawValue, "\(reply)")
        }
        try page.sendBinary(Array(TerminalRelay.frame(.bytes, stream: 1, Array("not typed".utf8)[...])))
        let id = try page.send("status", [:])
        let after = try #require(try page.next()?.json, "the connection ended after a binary frame")
        #expect(after["re"]?.string == id && after["ok"]?.bool == true, "\(after)")
        #expect(!node.said.contains("terminal stream"), "\(node.said)")

        let base = ["vibeswitcher-server", "--host-connector", "3", "--host-socket", "/x/host.sock"]
        let user = try ServerArguments.parse(base + ["--node", "--node-root", "/x/b", ServerArguments.testWebTerminalFlag]).get()
        #expect(user.refused == [ServerArguments.testWebTerminalFlag] && !user.testWebTerminal)
        let scratchServer = try ServerArguments.parse(base + ["--root", "/x", ServerArguments.testWebTerminalFlag]).get()
        #expect(scratchServer.refused.isEmpty && scratchServer.testWebTerminal)
        let open = NodeWire.Request(id: "t", kind: "term.open")
        #expect(WebAccess.refusal(for: open, rights: WebAccess.rights)?.error?.code == NodeWire.Code.unknownKind.rawValue)
        #expect(WebAccess.refusal(for: open, rights: WebAccess.rights, terminals: true) == nil)
        #expect(WebAccess.refusal(for: open, rights: [], terminals: true)?.error?.code == NodeWire.Code.voice.rawValue)
    }

    // MARK: Helpers

    /// A fake Claude Code on a session of `node`'s host, once it runs (its state file names its pid), and its files.
    static func fakeClaude(_ node: ScratchNode) async throws -> (HostSession, FakeClaude.Files) {
        let project = node.home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let session = try await node.spawn("exec \(FakeClaude.quoted(node.fake.launcher.path))", cwd: project.path)
        let files = node.fake.files(terminal: session.tty)
        try #require(await eventually(timeout: 60) { state(files)["pid"] != nil }, "the fake never ran: \(node.said)")
        return (session, files)
    }

    /// The server's lines about terminals.
    static func terminalLines(_ node: ScratchNode) -> String {
        node.said.split(separator: "\n").filter { $0.contains("terminal") }.joined(separator: "\n")
    }

    static func state(_ files: FakeClaude.Files) -> [String: Any] { EngineEndToEndTests.state(files) }
}

/// A page's WebSocket on a scratch node's listener for the terminal: its text frames as JSON (each checked against
/// the wire's schema, as `LivePage` checks them), its binary frames as the contract's terminal frames, and the
/// server's pings answered (a read that waits long doesn't lose the connection).
final class TermPage {
    struct Term: CustomStringConvertible {
        var kind: UInt8
        var stream: UInt32
        var payload: [UInt8]
        var description: String { "\(kind)@\(stream):\(payload.count)" }
    }

    enum Item: CustomStringConvertible {
        case json(NodeWire.Value)
        case term(Term)
        var json: NodeWire.Value? { if case .json(let value) = self { value } else { nil } }
        var term: Term? { if case .term(let term) = self { term } else { nil } }
        var description: String {
            switch self {
            case .json(let value): "\(value)"
            case .term(let term): "\(term)"
            }
        }
    }

    let client: RawClient
    private(set) var hello: NodeWire.Value?
    private(set) var unsound: [String] = []
    private var counter = 0

    init(port: UInt16) throws {
        client = try RawClient(port: port)
        let status = try client.upgrade(host: "127.0.0.1:\(port)", origin: "http://127.0.0.1:\(port)")
        guard status == 101 else { throw RawClient.Failure("the upgrade was answered \(status)") }
    }

    /// `web.open` in the scratch form, the upgrade, `auth` with the code, and its `hello`.
    static func paired(_ node: ScratchNode) throws -> TermPage {
        let opened = try LiveScratch.open(node)
        let page = try TermPage(port: opened.port)
        _ = try page.send("auth", ["pair": .string(opened.code), "client": .string("test")])
        page.hello = try page.next()?.json
        guard page.hello?["kind"]?.string == "hello" else { throw RawClient.Failure("no hello: \(String(describing: page.hello))") }
        return page
    }

    func send(_ kind: String, _ args: [String: NodeWire.Value]) throws -> String {
        counter += 1
        let id = String(counter)
        try client.sendText(String(decoding: NodeWire.message(NodeWire.Request(id: id, kind: kind, args: args)), as: UTF8.self))
        return id
    }

    /// `term.open` for `session` at 100 × 30: its stream, from the reply (which comes before any of its frames).
    func open(_ session: HostSession) throws -> UInt32 {
        let id = try send("term.open", ["session": .string(NodeIds.session(host: session.id)), "cols": .int(100), "rows": .int(30)])
        guard let reply = try next()?.json, reply["re"]?.string == id, let stream = reply["result"]?["stream"]?.int.flatMap(UInt32.init(exactly:)) else {
            throw RawClient.Failure("term.open wasn't answered with a stream")
        }
        return stream
    }

    /// `text` typed on `stream`: one type 1 frame.
    func type(_ text: String, on stream: UInt32) throws {
        try sendBinary(Array(TerminalRelay.frame(.bytes, stream: stream, Array(text.utf8)[...])))
    }

    /// `payload` as one masked binary frame.
    func sendBinary(_ payload: [UInt8]) throws {
        try write(Self.masked(0x2, payload))
    }

    /// The next text or binary message; nil when the connection ended or nothing came within the client's wait.
    func next() throws -> Item? {
        while let frame = try client.nextFrame() {
            switch frame.opcode {
            case 0x1:
                guard let json = frame.json else { throw RawClient.Failure("a text frame that isn't JSON") }
                if let failure = WireSchema.check(json, as: "frame") { unsound.append("\(failure): \(frame)") }
                return .json(json)
            case 0x2:
                let bytes = [UInt8](frame.payload)
                guard bytes.count >= 5 else { throw RawClient.Failure("a terminal frame of \(bytes.count) bytes") }
                return .term(Term(kind: bytes[0], stream: bytes[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, payload: Array(bytes[5...])))
            case 0x9:
                try write(Self.masked(0xA, [UInt8](frame.payload)))
            case 0x8:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// Messages until one `holds` (it last), or nil when the connection ends first.
    func until(_ holds: (Item) -> Bool) throws -> [Item]? {
        var seen: [Item] = []
        while let item = try next() {
            seen.append(item)
            if holds(item) { return seen }
        }
        return nil
    }

    private func write(_ bytes: [UInt8]) throws {
        let done = Data(bytes).withUnsafeBytes { RawClient.writeAll(client.fd, $0) }
        guard done else { throw RawClient.Failure("write: \(errno)") }
    }

    /// A client's frame: final, masked, with `opcode` and `payload`.
    static func masked(_ opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 0xffff {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }
}
