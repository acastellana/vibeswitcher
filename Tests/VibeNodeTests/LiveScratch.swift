import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// What the live plan's I1 cases share on a `ScratchNode`: a fake agent whose status a test sets as its hook would
/// (`HookedAgent`), the server's web flags, and a page's WebSocket (`LivePage`), every frame it reads checked against the
/// wire's schema (the contract's §10: "every frame a test client receives goes through the validators").
enum LiveScratch {
    /// The server's web, for a scratch node: the kernel's port, and `web.open` from any process of the uid.
    static let webArguments = ["--server-arg", ServerArguments.testWebPortFlag + "0", "--server-arg", ServerArguments.testWebPairFlag]

    /// `web.open` in the scratch form, on the server's socket: the page's address.
    static func open(_ node: ScratchNode, localhost: Bool = false) throws -> (url: String, port: UInt16, code: String) {
        let client = try WireClient(node)
        let reply = try #require(WireClient.reply(client.request("web.open", args: localhost ? ["localhost": .bool(true)] : nil)),
                                 "no reply to web.open: \(node.said)")
        let url = try #require(reply.result?["url"]?.string, "\(reply)")
        let rest = try #require(url.split(separator: ":").last.map(String.init))
        let port = try #require(UInt16(rest.prefix { $0.isNumber }), "\(url)")
        let code = try #require(url.components(separatedBy: "#pair=").last, "\(url)")
        return (url, port, code)
    }

    /// The page that took `code` confirmed as the terminal does (`web.pairing`'s phrase, then `web.confirm`), in the
    /// scratch form: its connection is sent its pairing secret (`paired`), and watches.
    static func confirm(_ node: ScratchNode, code: String) throws {
        let client = try WireClient(node)
        let id = PagePairing.codeID(digest: WebTokens.digest(code))
        let pairing = try #require(WireClient.reply(client.request("web.pairing", args: ["code": .string(id)], action: nil)), "no reply to web.pairing: \(node.said)")
        let phrase = try #require(pairing.result?["phrase"]?.string, "the page hasn't taken the code: \(pairing)")
        let confirmed = try #require(WireClient.reply(client.request("web.confirm", args: ["code": .string(id), "phrase": .string(phrase)])),
                                     "no reply to web.confirm: \(node.said)")
        try #require(confirmed.ok, "\(confirmed)")
    }
}

/// Stage 1's fake agent on a session of the node's host (`ServerTests.statusThroughTheServerListsWhatTheProbeLists`'s):
/// a copy of `sleep` named `claude`, its status what the state file its hook would write says.
struct HookedAgent {
    let session: HostSession
    let pid: pid_t
    let folder: URL

    /// `folder`: where it works (`project` under the home by default); `label`: its host label ("Lead · NAME" makes it a
    /// lead session of the project at `folder`, as a lead the project replaced is).
    static func start(_ node: ScratchNode, project: String = "project", folder at: URL? = nil, label: String = "Test") async throws -> HookedAgent {
        let folder = at ?? node.home.appendingPathComponent(project)
        let bin = node.root.appendingPathComponent("fake-bin")
        for made in [folder, bin] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        let claude = bin.appendingPathComponent("claude")
        if !FileManager.default.fileExists(atPath: claude.path) {
            try copyClosedOnExec(URL(fileURLWithPath: "/bin/sleep").resolvingSymlinksInPath().path, to: claude.path)
        }
        let session = try await node.spawn("exec '\(claude.path)' 600", cwd: folder.path, label: label, agent: "claude")
        var found: pid_t = 0
        let started = await eventually(timeout: 60) {
            found = Platform.Processes.children(session.childPID).first ?? session.childPID
            return ProcessTable.info(pid: found)?.comm == "claude" || ProcessTable.info(pid: session.childPID)?.comm == "claude"
        }
        try #require(started, "the fake agent never ran")
        let pid = ProcessTable.info(pid: session.childPID)?.comm == "claude" ? session.childPID : found
        return HookedAgent(session: session, pid: pid, folder: folder)
    }

    /// Its hook's state now says `event` (`PermissionRequest`: needs you; `UserPromptSubmit`: working; `Stop`: done).
    /// `transcript`: the transcript its hook names (a file in the node's `~/.claude/projects`), for its chat.
    func hook(_ node: ScratchNode, _ event: String, transcript: URL? = nil) throws {
        var state = HookState(agent: .claude, tty: session.tty, lastEvent: event, lastEventAt: Date().timeIntervalSince1970)
        state.agentPid = pid
        state.cwd = folder.path
        state.transcriptPath = transcript?.path
        let states = node.root.appendingPathComponent("state")
        try VibePaths.ensurePrivate(states)
        try state.save(to: states.appendingPathComponent("\(session.tty).json"))
    }

    var id: String { NodeIds.session(host: session.id) }
}

/// A page's WebSocket on a scratch node's listener: its upgrade from the page's own origin, then frames as JSON, each
/// checked against the wire's schema as it is read.
final class LivePage {
    let client: RawClient
    let port: UInt16
    private var counter = 0
    /// Frames that failed the schema, with why.
    private(set) var unsound: [String] = []

    init(port: UInt16) throws {
        self.port = port
        client = try RawClient(port: port)
        let status = try client.upgrade(host: "127.0.0.1:\(port)", origin: "http://127.0.0.1:\(port)")
        guard status == 101 else { throw RawClient.Failure("the upgrade was answered \(status)") }
    }

    /// `kind` with `args` (and an `action` id, for an action such as a draft): the request's id.
    func send(_ kind: String, _ args: [String: NodeWire.Value], action: String? = nil) throws -> String {
        counter += 1
        let id = String(counter)
        try client.sendText(String(decoding: NodeWire.message(NodeWire.Request(id: id, kind: kind, args: args, action: action)), as: UTF8.self))
        return id
    }

    /// Why the last `next()` gave nil: nothing within the client's wait, or a frame that isn't JSON (a close, with its
    /// code). For a failure's message.
    private(set) var ended = ""

    /// The next frame, checked; nil when the connection ended or nothing came within the client's wait.
    func next() throws -> NodeWire.Value? {
        let asked = Date()
        var got = try client.nextFrame()
        // The listener's keepalive (a ping every `pingSeconds` while the page is open, answered as a browser does): never
        // the end of anything. Under load it came before a subscription's snapshot (the CI flake of 2026-11-23).
        while let frame = got, frame.opcode == 0x9 || frame.opcode == 0xA {
            if frame.opcode == 0x9 { try client.sendPong(frame.payload) }
            got = try client.nextFrame()
        }
        guard let frame = got else {
            ended = "nothing came in \(Int(Date().timeIntervalSince(asked))) s"
            return nil
        }
        guard let json = frame.json else {
            ended = "a frame that isn't JSON: \(frame)"
            return nil
        }
        if let failure = WireSchema.check(json, as: "frame") { unsound.append("\(failure): \(frame)") }
        return json
    }

    /// Frames until one `holds` (it last), or nil when the connection ends first.
    func until(_ holds: (NodeWire.Value) -> Bool) throws -> [NodeWire.Value]? {
        var seen: [NodeWire.Value] = []
        while let frame = try next() {
            seen.append(frame)
            if holds(frame) { return seen }
        }
        ended += "; before it, \(seen.count) frames: " + seen.prefix(5).map { "\($0["kind"]?.string ?? "?") re \($0["re"]?.string ?? "-")" }.joined(separator: ", ")
        return nil
    }
}
