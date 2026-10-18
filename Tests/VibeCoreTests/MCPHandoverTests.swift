import Darwin
import Foundation
import Testing
@testable import VibeCore

private final class Anchor {}

/// The built `vibeswitcher-mcp`, beside this test bundle.
private let toolServer = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path

/// A real `vibeswitcher-mcp` process on real pipes, in a scratch home, installed at `installed`, with this test as its
/// MCP client. Its builds are scripts standing in for one: each runs the built tool server as a test build
/// (`VIBESWITCHER_MCP_TEST_BUILD`, see its main.swift), whose tools say which build answers, from which process.
final class ScratchToolServer {
    let dir: URL
    let installed: String
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var replies: [Int: [String: Any]] = [:]
    private var notified: [String] = []

    init(_ scratch: Scratch) throws {
        dir = scratch.url("mcp-handover")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        installed = dir.appendingPathComponent("vibeswitcher-mcp").path
        #expect(FileManager.default.isExecutableFile(atPath: toolServer), "swift build makes \(toolServer)")
        try install(build: "A")
        process.executableURL = URL(fileURLWithPath: installed)
        process.arguments = ["--root", dir.path]
        process.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path, "PATH": "/usr/bin:/bin",
                               "TMPDIR": dir.path + "/", "VIBESWITCHER_MCP_TEST_BINARY": installed]
        let log = dir.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle.availableData) }
        try process.run()
    }

    deinit { stop() }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    var log: String { (try? String(contentsOf: dir.appendingPathComponent("server.log"), encoding: .utf8)) ?? "" }

    /// Installs a build as an install does: written beside the binary, then renamed over it.
    func install(build: String) throws {
        try install("#!/bin/sh\nVIBESWITCHER_MCP_TEST_BUILD=\(build) exec '\(toolServer)' \"$@\"\n")
    }

    func install(_ script: String, mode: Int = 0o755) throws {
        let next = dir.appendingPathComponent("next").path
        FileManager.default.createFile(atPath: next, contents: Data(script.utf8), attributes: [.posixPermissions: mode])
        #expect(rename(next, installed) == 0)
    }

    /// Writes the messages in one go, a line each.
    func send(_ messages: [[String: Any]]) throws {
        var data = Data()
        for message in messages { data += try JSONSerialization.data(withJSONObject: message) + Data([0x0A]) }
        input.fileHandleForWriting.write(data)
    }

    func call(_ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
    }

    /// The reply to request `id`, once it's come.
    func reply(_ id: Int) throws -> [String: Any] {
        var found: [String: Any]?
        _ = eventually {
            lock.lock()
            found = replies[id]
            lock.unlock()
            return found != nil
        }
        return try #require(found, "no reply to \(id); the server's log: \(log)")
    }

    /// A tool call's text: the build that answered and its process, then any notice.
    func texts(_ id: Int) throws -> [String] {
        let content = try #require((try reply(id)["result"] as? [String: Any])?["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }
    }

    func tools(_ id: Int) throws -> [String] {
        try #require((try reply(id)["result"] as? [String: Any])?["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String }
    }

    /// The notifications the server sent, in order.
    var notifications: [String] {
        lock.lock()
        defer { lock.unlock() }
        return notified
    }

    private func read(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer += data
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<end])
            buffer = Data(buffer[buffer.index(after: end)...])
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let id = message["id"] as? Int { replies[id] = message } else if let method = message["method"] as? String { notified.append(method) }
        }
    }

    static let initialize: [[String: Any]] = [
        ["jsonrpc": "2.0", "id": 0, "method": "initialize",
         "params": ["protocolVersion": "2025-11-25", "capabilities": ["roots": ["listChanged": true]],
                    "clientInfo": ["name": "claude-code", "version": "2.1.302"]]],
        ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
    ]
}

struct MCPHandoverTests {
    let scratch = Scratch()

    @Test func aClientKeepsItsSessionAcrossANewBuild() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize + [server.call(2, "build")])
        let initialized = try #require(try server.reply(0)["result"] as? [String: Any])
        #expect((initialized["capabilities"] as? [String: Any])?["tools"] as? [String: Bool] == ["listChanged": true])
        #expect(try server.tools(1) == ["build", "slow", "only-A"])
        let pid = server.process.processIdentifier
        #expect(try server.texts(2) == ["A \(pid)"])

        try server.install(build: "B")
        // Two calls in one write: the second is input the old build read but never handled.
        try server.send([server.call(3, "build"), server.call(4, "build")])
        #expect(try server.texts(3) == ["B \(pid)"])
        #expect(try server.texts(4) == ["B \(pid)"])
        // The same process, still running, on the same pipes: no disconnect, no new initialize.
        #expect(server.process.isRunning)
        #expect(server.notifications == ["notifications/tools/list_changed"])
        try server.send([["jsonrpc": "2.0", "id": 5, "method": "tools/list"]])
        #expect(try server.tools(5) == ["build", "slow", "only-B"])
        #expect(server.log.contains("switched in place to the new build"))

        // And on to the next build, the same way.
        try server.install(build: "C")
        try server.send([server.call(6, "build")])
        #expect(try server.texts(6) == ["C \(pid)"])
        #expect(server.notifications == ["notifications/tools/list_changed", "notifications/tools/list_changed"])
    }

    /// The old build finishes what it has in hand, answering it, before the new one takes over.
    @Test func aCallInHandIsFinishedByTheOldBuild() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize + [server.call(2, "slow", ["seconds": 3])])
        _ = try server.reply(1)
        let pid = server.process.processIdentifier
        try server.install(build: "B")
        // While the slow call runs, the old build goes on serving.
        try server.send([server.call(3, "build")])
        #expect(try server.texts(3) == ["A \(pid)"])
        #expect(try server.texts(2) == ["A \(pid)"])
        try server.send([server.call(4, "build")])
        #expect(try server.texts(4) == ["B \(pid)"])
        #expect(server.process.isRunning)
    }

    @Test func aBuildThatCantTakeOverLeavesTheOldOneServing() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let pid = server.process.processIdentifier

        // A build that won't run.
        try server.install("#!/bin/sh\necho 'this build is broken' >&2\nexit 3\n")
        try server.send([server.call(2, "build")])
        let broken = try server.texts(2)
        #expect(broken.first == "A \(pid)")
        #expect(broken.count == 2 && broken[1].contains("couldn't switch to the new build (its probe exited with status 3)"))
        #expect(server.log.contains("this build is broken"))
        #expect(server.log.contains("couldn't switch to the new build at \(server.installed): its probe exited with status 3; this build serves on"))

        // One that can't be executed at all.
        try server.install("#!/bin/sh\nexit 0\n", mode: 0o644)
        try server.send([server.call(3, "build")])
        #expect(try server.texts(3).first == "A \(pid)")
        #expect(server.log.contains("it couldn't start: Permission denied"))

        // One that refuses the session: an answer that isn't the probe's.
        try server.install("#!/bin/sh\necho 'vibeswitcher-mcp handover 999 ok'\n")
        try server.send([server.call(4, "build")])
        #expect(try server.texts(4).first == "A \(pid)")
        #expect(server.log.contains("its probe said vibeswitcher-mcp handover 999 ok"))
        // Through all of it the old build kept its tools.
        try server.send([["jsonrpc": "2.0", "id": 5, "method": "tools/list"]])
        #expect(try server.tools(5) == ["build", "slow", "only-A"])

        // A good build then takes over at once.
        try server.install(build: "B")
        try server.send([server.call(6, "build")])
        #expect(try server.texts(6) == ["B \(pid)"])
    }
}

struct MCPSessionTests {
    func send(_ server: MCPServer, _ object: [String: Any]) throws {
        _ = server.handle(try JSONSerialization.data(withJSONObject: object))
    }

    @Test func theSessionIsWhatTheClientSetUp() throws {
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: MCPServerTests.Echo())
        #expect(server.currentSession == MCPSession())
        try send(server, ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                          "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code"], "capabilities": [:]]])
        try send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let session = server.currentSession
        #expect(session.protocolVersion == "2025-06-18")
        #expect(session.initialized)
        #expect(session.announcesToolChanges)
        #expect(session.tools == MCPServer.digest(MCPServerTests.Echo().tools))
        let client = try #require(session.client.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((client["clientInfo"] as? [String: Any])?["name"] as? String == "claude-code")
    }

    /// The guard rail: what goes to the new build is the MCP session and the input, never who the caller is. The new
    /// build asks the session host for its role, as at a fresh start.
    @Test func theHandoverCarriesNoRole() throws {
        var session = MCPSession()
        session.protocolVersion = "2025-11-25"
        session.client = Data("{}".utf8)
        session.tools = "digest"
        let state = MCPHandover.State(session: session, input: Data("x".utf8), binary: .init(modified: 1, size: 2, inode: 3))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(Set(json.keys) == ["format", "session", "input", "binary"])
        #expect(Set((json["session"] as? [String: Any])?.keys ?? [:].keys)
                == ["protocolVersion", "client", "initialized", "announcesToolChanges", "tools"])
        #expect(MCPHandover.decode(try JSONEncoder().encode(state)) == state)
        var other = state
        other.format = MCPHandover.format + 1
        #expect(MCPHandover.decode(try JSONEncoder().encode(other)) == nil)
        #expect(MCPHandover.decode(Data("not json".utf8)) == nil)
    }

    /// The new build's side, in this process: it answers the input carried over first, and tells a client that got
    /// another build's tools to ask again.
    @Test func aResumedServerGoesOnWithTheSession() throws {
        var session = MCPSession()
        session.initialized = true
        session.announcesToolChanges = true
        session.tools = "another build's tools"
        // A ping: answered on this thread, so before `serve` returns (a call's answer could come after).
        let carried = Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8 + [0x0A])
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: MCPServerTests.Echo(),
                               resuming: MCPHandover.State(session: session, input: carried, binary: nil))
        #expect(server.currentSession == session)
        let input = Pipe()
        let output = Pipe()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            server.serve(input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
            done.signal()
        }
        try input.fileHandleForWriting.close()
        #expect(done.wait(timeout: .now() + hangGuard) == .success)
        try output.fileHandleForWriting.close()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first == #"{"jsonrpc":"2.0","method":"notifications\/tools\/list_changed"}"#)
        #expect(lines.last == #"{"id":7,"jsonrpc":"2.0","result":{}}"#)

        // The same tools: nothing to tell.
        session.tools = MCPServer.digest(MCPServerTests.Echo().tools)
        let same = MCPServer(name: "vibeswitcher", version: "1", toolset: MCPServerTests.Echo(),
                             resuming: MCPHandover.State(session: session, input: Data(), binary: nil))
        let quiet = Pipe()
        let closed = Pipe()
        try closed.fileHandleForWriting.close()
        same.serve(input: closed.fileHandleForReading.fileDescriptor, output: quiet.fileHandleForWriting.fileDescriptor)
        try quiet.fileHandleForWriting.close()
        #expect(quiet.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
