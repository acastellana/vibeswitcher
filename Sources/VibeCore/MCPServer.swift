import Foundation

/// A tool as `tools/list` describes it; its arguments are an object of named properties.
public struct MCPToolInfo {
    public struct Property {
        public var type: String
        public var description: String
        /// For `array` properties: the type of the items.
        public var items: String?
        public var options: [String]?

        public init(type: String, description: String, items: String? = nil, options: [String]? = nil) {
            self.type = type
            self.description = description
            self.items = items
            self.options = options
        }

        var json: [String: Any] {
            var object: [String: Any] = ["type": type, "description": description]
            if let items { object["items"] = ["type": items] }
            if let options { object["enum"] = options }
            return object
        }
    }

    public var name: String
    public var description: String
    public var properties: [String: Property]
    public var required: [String]

    public init(name: String, description: String, properties: [String: Property] = [:], required: [String] = []) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
    }

    var json: [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties.mapValues(\.json), "required": required] as [String: Any]]
    }
}

public struct MCPToolResult {
    public var text: String
    public var isError: Bool
    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Whether the binary this server runs from is still the one on disk. An app update replaces it, but a running
/// server keeps the code it started with (an old lead's tools would still branch from main, say) until its client
/// reconnects it; killing it isn't enough, Claude Code doesn't start it again by itself. So once the file at `path`
/// is another binary, every tool result says so, until this process ends.
public final class BinaryWatch: @unchecked Sendable {
    public static let notice = "VibeSwitcher was updated; reconnect the vibeswitcher tools: /mcp"

    /// A file as `stat` sees it: an install writes a new file (another inode) or rewrites it (another time or size).
    public struct Identity: Equatable {
        public var modified: TimeInterval
        public var size: Int64
        public var inode: UInt64
        public init(modified: TimeInterval, size: Int64, inode: UInt64) {
            self.modified = modified
            self.size = size
            self.inode = inode
        }
    }

    private let path: String
    private let identify: (String) -> Identity?
    private let started: Identity?
    private let lock = NSLock()
    private var replaced = false

    /// Takes the binary's identity now: create it as the server starts.
    public init(path: String, identify: @escaping (String) -> Identity? = BinaryWatch.identity(of:)) {
        self.path = path
        self.identify = identify
        started = identify(path)
    }

    /// The notice for a tool result, or nil while the binary is the one this server started from. A missing file
    /// (mid-install, or moved) is no notice, and neither is a binary that couldn't be read at start: no way to tell.
    public func notice() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if !replaced, let started, let now = identify(path), now != started { replaced = true }
        return replaced ? Self.notice : nil
    }

    public static func identity(of path: String) -> Identity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return Identity(modified: modified, size: Int64(info.st_size), inode: UInt64(info.st_ino))
    }
}

public protocol MCPToolset: AnyObject {
    var tools: [MCPToolInfo] { get }
    func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult
}

/// MCP over stdio: one JSON-RPC 2.0 message per line in, one reply per line out (none for notifications). Tool
/// calls run side by side (a 20-minute merge doesn't make `status` or `ping` wait), and a cancelled call's commands
/// are stopped. With a `watch`, results say when the app was updated under the running server.
public final class MCPServer: @unchecked Sendable {
    private let name: String
    private let version: String
    private let toolset: MCPToolset
    private let watch: BinaryWatch?
    private let calls = DispatchQueue(label: "vibeswitcher.mcp-calls", attributes: .concurrent)
    private let lock = NSLock()
    private var running: [String: ShellCancel] = [:]

    public init(name: String, version: String, toolset: MCPToolset, watch: BinaryWatch? = nil) {
        self.name = name
        self.version = version
        self.toolset = toolset
        self.watch = watch
    }

    /// Reads requests from stdin until it closes, answering on stdout.
    public func serve() {
        let output = NSLock()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            receive(Data(line.utf8)) { reply in
                output.lock()
                FileHandle.standardOutput.write(reply + Data([0x0A]))
                output.unlock()
            }
        }
    }

    /// One incoming message: tool calls are answered when they finish (on another thread), the rest at once.
    public func receive(_ data: Data, respond: @escaping (Data) -> Void) {
        let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let method = message?["method"] as? String
        if method == "tools/call", let id = message?["id"] {
            let token = ShellCancel()
            let key = "\(id)"
            lock.lock()
            running[key] = token
            lock.unlock()
            calls.async { [self] in
                let reply = ShellCancel.with(token) { handle(data) }
                lock.lock()
                running[key] = nil
                lock.unlock()
                if let reply { respond(reply) }
            }
            return
        }
        if method == "notifications/cancelled", let params = message?["params"] as? [String: Any], let request = params["requestId"] {
            lock.lock()
            running["\(request)"]?.cancel()
            lock.unlock()
        }
        if let reply = handle(data) { respond(reply) }
    }

    public func handle(_ data: Data) -> Data? {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        // Notifications (no id) get no reply.
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-06-18"
            return reply(id, ["protocolVersion": requested, "capabilities": ["tools": [String: Any]()],
                              "serverInfo": ["name": name, "version": version]])
        case "ping":
            return reply(id, [String: Any]())
        case "tools/list":
            return reply(id, ["tools": toolset.tools.map(\.json)])
        case "tools/call":
            let tool = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = toolset.call(tool, arguments)
            var content = [["type": "text", "text": result.text]]
            if let notice = watch?.notice() { content.append(["type": "text", "text": notice]) }
            return reply(id, ["content": content, "isError": result.isError])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func reply(_ id: Any, _ result: [String: Any]) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
