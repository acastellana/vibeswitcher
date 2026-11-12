import Foundation
import Testing
import VibeCore

/// The built tool server (`vibeswitcher-mcp`) answers its client over stdio with no session host running: it learns
/// its role from the host, so it lists no tools yet, and says on stderr that it asks again. The lead's tools listed and
/// one call served are stage 2's check (`ToolServerUnderAHostTests`), once a host runs on Linux.
struct ToolServerSmokeTests {
    private let scratch = Scratch()

    /// The built tool server, beside this test bundle.
    static let toolServer = builtProducts.appendingPathComponent("vibeswitcher-mcp")

    @Test func theToolServerAnswersWithNoHost() async throws {
        let folder = scratch.url("tool-server")
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("home"), withIntermediateDirectories: true)
        let server = try ToolServer(Self.toolServer, root: project, environment: scratchEnvironment(folder), log: folder.appendingPathComponent("stderr.log"))
        defer { server.stop() }

        try server.send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                    "clientInfo": ["name": "ToolServerSmokeTests", "version": "1"]]])
        let initialized = try #require(await server.reply(1, within: 10), "no answer to initialize within 10 s; stderr: \(server.errors)")
        let result = try #require(initialized["result"] as? [String: Any], "\(initialized)")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "vibeswitcher")

        try server.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try server.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let listed = try #require(await server.reply(2, within: 10), "no answer to tools/list; stderr: \(server.errors)")
        let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [Any], "\(listed)")
        #expect(tools.isEmpty, "\(tools)")
        #expect(server.errors.contains("the session host can't be asked yet, or its session holds no role yet; asking again"),
                "\(server.errors)")
    }
}

/// A tool server process on pipes, with this test as its MCP client (a JSON message a line each way).
final class ToolServer: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let log: URL
    private let lock = NSLock()
    private var buffer = Data()
    private var replies: [Int: [String: Any]] = [:]

    init(_ executable: URL, root: URL, environment: [String: String], log: URL) throws {
        self.log = log
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.executableURL = executable
        process.arguments = ["--root", root.path]
        process.environment = environment
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: log)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle.availableData) }
        try process.run()
    }

    /// What it wrote to stderr so far.
    var errors: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    func send(_ message: [String: Any]) throws {
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + Data([0x0A]))
    }

    /// The reply to request `id`, once it's come; nil past `seconds`.
    func reply(_ id: Int, within seconds: TimeInterval) async -> [String: Any]? {
        var found: [String: Any]?
        _ = await eventually(timeout: seconds) { [self] in
            lock.lock()
            found = replies[id]
            lock.unlock()
            return found != nil
        }
        return found
    }

    /// Closes its input, as a client that's gone does, and ends it if that doesn't.
    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        let deadline = MacTime.real.awake() + 10
        while process.isRunning, MacTime.real.awake() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let killed = MacTime.real.awake() + 10
        while process.isRunning, MacTime.real.awake() < killed { Thread.sleep(forTimeInterval: 0.01) }
    }

    private func read(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer += data
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer = Data(buffer[buffer.index(after: end)...])
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = message["id"] as? Int else { continue }
            replies[id] = message
        }
    }
}
