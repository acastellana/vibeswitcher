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
    static func open(_ node: ScratchNode) throws -> (url: String, port: UInt16, code: String) {
        let client = try WireClient(node)
        let reply = try #require(WireClient.reply(client.request("web.open")), "no reply to web.open: \(node.said)")
        let url = try #require(reply.result?["url"]?.string, "\(reply)")
        let rest = try #require(url.split(separator: ":").last.map(String.init))
        let port = try #require(UInt16(rest.prefix { $0.isNumber }), "\(url)")
        let code = try #require(url.components(separatedBy: "#pair=").last, "\(url)")
        return (url, port, code)
    }
}

/// Stage 1's fake agent on a session of the node's host (`ServerTests.statusThroughTheServerListsWhatTheProbeLists`'s):
/// a copy of `sleep` named `claude`, its status what the state file its hook would write says.
struct HookedAgent {
    let session: HostSession
    let pid: pid_t
    let folder: URL

    static func start(_ node: ScratchNode, project: String = "project") async throws -> HookedAgent {
        let folder = node.home.appendingPathComponent(project)
        let bin = node.root.appendingPathComponent("fake-bin")
        for made in [folder, bin] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        let claude = bin.appendingPathComponent("claude")
        if !FileManager.default.fileExists(atPath: claude.path) {
            try copyClosedOnExec(URL(fileURLWithPath: "/bin/sleep").resolvingSymlinksInPath().path, to: claude.path)
        }
        let session = try await node.spawn("exec '\(claude.path)' 600", cwd: folder.path)
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

    func send(_ kind: String, _ args: [String: NodeWire.Value]) throws -> String {
        counter += 1
        let id = String(counter)
        try client.sendText(String(decoding: NodeWire.message(NodeWire.Request(id: id, kind: kind, args: args)), as: UTF8.self))
        return id
    }

    /// The next frame, checked; nil when the connection ended or nothing came within the client's wait.
    func next() throws -> NodeWire.Value? {
        guard let frame = try client.nextFrame() else { return nil }
        guard let json = frame.json else { return nil }
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
        return nil
    }
}
